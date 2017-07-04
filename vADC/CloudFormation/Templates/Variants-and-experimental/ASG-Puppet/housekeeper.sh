#!/bin/bash
#
# This script is customised during vADC instance deployment by cfn-init
# Please see example usage in the CloudFormation template:
# https://github.com/dkalintsev/Brocade/blob/master/vADC/CloudFormation/Templates/Variants-and-experimental/ASG-Puppet/vADC-ASG-Puppet.template
#
# The purpose of this script is to perform housekeeping on a running vADC cluster:
# - Remove vADC nodes that aren't in "running" state
# - Add or remove secondary private IPs to vADC node to match number of configured Traffic IPs in the cluster
#   * this is to help deal with Traffic IPs as each EIP needs a secondary private IP
#
# We expect the following vars passed in:
# ClusterID = AWS EC2 tag used to find vADC instances in our cluster
# Region = AWS::Region
# Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.
#
# vADC instances running this script will need to have an IAM Role with the Policy allowing:
# - ec2:DescribeInstances
# - ec2:CreateTags
# - ec2:DeleteTags
#
export PATH=$PATH:/usr/local/bin
export ZEUSHOME=/opt/zeus
logFile="/var/log/housekeeper.log"
configDir="/opt/zeus/zxtm/conf/zxtms"
configSync="/opt/zeus/zxtm/bin/replicate-config"

clusterID="{{ClusterID}}"
region="{{Region}}"
verbose="{{Verbose}}"

# Tag for Housekeeping
housekeeperTag="HousekeepingState"

# Value for when running Housekeeping
statusWorking="Working"

# Creating temp filenames to keep lists of running and clustered instances, and delta between the two.
#
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
runningInstF="/tmp/running.$rand_str"
clusteredInstF="/tmp/clustered.$rand_str"
deltaInstF="/tmp/delta.$rand_str"
filesF="/tmp/files.$rand_str"
resFName="/tmp/aws-out.$rand_str"
jqResFName="/tmp/jq-out.$rand_str"
awscliLogF="/var/log/housekeeper-out.log"
dnsIPs="/tmp/dnsIPs.$rand_str"
activeIPs="/tmp/activeIPs.$rand_str"
changeSetF="/tmp/changeSetF.$rand_str"

lockF=/tmp/housekeeper.lock

cleanup  () {
    rm -f $runningInstF $clusteredInstF $deltaInstF $filesF
    rm -f $resFName $jqResFName
    rm -f $dnsIPs $activeIPs $changeSetF
    rm -f $lockF
}

trap cleanup EXIT

logMsg () {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >> $logFile
    fi
}

if [[ "$verbose" == "" ]]; then
    # there's no such thing as too much logging ;)
    verbose="Yes"
fi

if [[ -f $lockF ]]; then
    logMsg "001: Found lock file, exiting."
    exit 1
fi

# We need jq, which should have been installed by now.
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "002: Looks like jq isn't installed; quiting."
    exit 1
fi

# We also need aws cli tools.
which aws >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "003: Looks like AWS CLI tools isn't installed; quiting."
    exit 1
fi

myInstanceID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Execute AWS CLI command "safely": if error occurs - backoff exponentially
# If succeeded - return 0 and save output, if any, in $resFName
# Given this script runs once only, the "failure isn't an option".
# So this func will block till the cows come home.
#
safe_aws () {
    errCode=1
    backoff=0
    retries=0
    while [[ "$errCode" != "0" ]]; do
        let "backoff = 2**retries"
        if (( $retries > 5 )); then
            # Exceeded retry budget of 5.
            # Doing random sleep up to 45 sec, then back to try again.
            backoff=$RANDOM
            let "backoff %= 45"
            logMsg "004: safe_aws \"$*\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff
            retries=0
            backoff=1
        fi
        aws $* > $resFName 2>>$awscliLogF
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "005: AWS CLI returned error $errCode; sleeping for $backoff seconds.."
            sleep $backoff
            let "retries += 1"
        fi
        # We are assuming that aws cli produced valid JSON output or "".
        # While this is thing worth checking, we'll just leave it alone for now.
        # jq '.' $resFName > /dev/null 2>&1
        # errCode=$?
    done
    return 0
}

# Set tag on $myInstanceID
# $1 = tag
# $2 = value
#
setTag () {
    logMsg "006: Setting tags on $myInstanceID: \"$1:$2\""
    safe_aws ec2 create-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1,Value=$2
    # Check if I can find myself by the newly applied tag
    declare -a stList
    unset stList
    while [[ ${#stList[*]} == 0 ]]; do
        findTaggedInstances $1 $2
        stList=( $(cat $jqResFName | grep "$myInstanceID") )
        logMsg "007: Checking tagged instances \"$1:$2\", expecting to see $myInstanceID; got \"$stList\""
        if [[ ${#stList[*]} == 1 ]]; then
            logMsg "008: Found us, we're done."
        else
            logMsg "009: Not yet; sleeping for a bit."
            sleep 3
        fi
    done
    return 0
}

# Remove tag from $myInstanceID
# $1 = tag
# $2 = value (need for success checking)
#
delTag () {
    logMsg "010: Deleting tags: \"$1:$2\""
    safe_aws ec2 delete-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1
    # Check if we don't come up when searching for the tag, i.e., tag is gone
    declare -a stList
    stList=( blah )
    while [[ ${#stList[*]} > 0 ]]; do
        findTaggedInstances $1 $2
        stList=( $(cat $jqResFName | grep "$myInstanceID") )
        logMsg "011: Checking tagged instances \"$1:$2\", expecting NOT to see $myInstanceID; got \"$stList\""
        if [[ ${#stList[*]} == 0 ]]; then
            logMsg "012: Tag \"$1:$2\" is not there, we're done."
        else
            logMsg "013: Not yet; sleeping for a bit."
            sleep 3
        fi
    done
    return 0
}

# Returns list of instances with matching tags
# $1 tag
# $2 value
#
findTaggedInstances () {
    # We operate only on instances that are both
    # "running" and have "ClusterID" = $clusterID
    filter="Name=tag:ClusterID,Values=$clusterID \
            Name=instance-state-name,Values=running"

    # if we're given tag and value, look for these; if not - just return running instances with our ClusterID
    if [ $# -eq "2" ]; then
        filter=$filter" Name=tag:$1,Values=$2"
    fi

    # Run describe-instances and make sure we get valid JSON (which includes empty file)
    safe_aws ec2 describe-instances --region $region \
        --filters $filter --output json
    cat $resFName | jq -r ".Reservations[].Instances[].InstanceId" > $jqResFName
    return 0
}

# function getLock - makes sure we're the only running instance with the
# $stateTag == Tag passed to us as function parameter
#
# $1 & $2 = tag & value to lock on for myInstanceID
getLock () {
    declare -a list
    while true; do
        list=( blah )
        # Get a list of instances with $stateTag = $tag other than us
        # if there are any, wait 5 seconds, then retry until there are none
        while [[ ${#list[*]} > 0 ]]; do
            logMsg "014: Looping until there's no instance matching \"$1:$2\""
            findTaggedInstances $1 $2
            list=( $(cat $jqResFName | grep -v $myInstanceID) )
            if [[ ${#list[*]} > 0 ]]; then
                s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
                logMsg "015: Found some: \"$s_list\", sleeping..."
                sleep 5
            fi
        done
        # Do we already have the tag by chance?
        list=( $(cat $jqResFName | grep "$myInstanceID") )
        if [[ ${#list[*]} == 1 ]]; then
            logMsg "016: We already have that tag, returning."
            return 0
        fi
        # once there aren't any, tag ourselves
        logMsg "017: Tagging ourselves: \"$1:$2\""
        setTag $1 $2
        list=( blah )
        # check if there are other tagged instances who managed to beat us to it
        while [[ ${#list[*]} > 0 ]]; do
            findTaggedInstances $1 $2
            list=( $(cat $jqResFName | grep -v "$myInstanceID") )
            s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
            logMsg "018: Looking for others with the same tags, found: \"$s_list\""
            if [[ ${#list[*]} > 0 ]]; then
                # there's someone else - clash
                logMsg "019: Clash detected, calling delTag: \"$1:$2\""
                delTag $1 $2
                backoff=$RANDOM
                let "backoff %= 25"
                # do random backoff, then bail to the mail while().
                logMsg "020: Backing off for $backoff seconds"
                sleep $backoff
                unset list
            else
                # lock obtained; we're done here.
                logMsg "021: Got our lock, returning."
                return 0
            fi
        done
    done
}

# First, do random sleep to avoid race with other cluster nodes, since we're running from cron.
#
backoff=$RANDOM
let "backoff %= 25"
logMsg "022: Running initial backoff for $backoff seconds"
sleep $backoff

cleanup
touch $lockF

declare -a list
findTaggedInstances $housekeeperTag $statusWorking
list=( $(cat $jqResFName | grep -v $myInstanceID) )
s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
logMsg "023: Checking if an other node is already running Housekeeping; got: \"$s_list\""
if [[ ${#list[*]} > 0 ]]; then
    logMsg "024: Yep, somebody beat us to it. Exiting."
    exit 0
else
    logMsg "025: Ok, let's get to work."
fi

logMsg "026: Getting lock on $statusWorking.."
getLock "$housekeeperTag" "$statusWorking"

# List running instances in our vADC cluster
logMsg "027: Checking running instances.."
findTaggedInstances
cat $jqResFName | sort -rn > $runningInstF
# Sanity check - we should see ourselves in the $jqResFName
list=( $(cat $jqResFName | grep "$myInstanceID") )
if [[ ${#list[*]} == 0 ]]; then
    # LOL WAT
    logMsg "028: Cant't seem to be able to find ourselves running; did you set ClusterID correctly? I have: \"$clusterID\". Bailing."
    exit 1
fi

# Go to cluster config dir, and look for instanceIDs in config files there
logMsg "029: Checking clustered instances.."
cd $configDir
grep -i instanceid * | awk '{print $2}' | sort -rn | uniq > $clusteredInstF
# Compare the two, looking for lines that are present in the cluster config but missing in running list
logMsg "030: Comparing list of running and clustered instances.."
diff $clusteredInstF $runningInstF | awk '/^</ { print $2 }' > $deltaInstF
# Check if our InstanceId is in the list of running
# ***************

if [[ -s $deltaInstF ]]; then
    # There is some delta - $deltaInstF isn't empty
    declare -a list
    list=( $(cat $deltaInstF) )
    s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
    logMsg "031: Delta detected - need to do clean up the following instances: $s_list."
    for instId in ${list[@]}; do
        grep -l "$instId" * >> $filesF 2>/dev/null
    done
    if [[ -s $filesF ]]; then
        svIFS=$IFS
        IFS=$(echo -en "\n\b")
        files=( $(cat $filesF) )
        IFS=$svIFS
        for file in "${files[@]}"; do
            logMsg "032: Deleting $file.."
            rm -f "$file"
        done
        logMsg "033: Synchronising cluster state and sleeping to let things settle.."
        $configSync
        sleep 60
        logMsg "034: All done, exiting."
    else
        logMsg "035: Hmm, can't find config files with matching instanceIDs; maybe somebody deleted them already. Exiting."
    fi
    delTag "$housekeeperTag" "$statusWorking"
else
    logMsg "036: No delta, exiting."
    delTag "$housekeeperTag" "$statusWorking"
fi

# Make sure this instance has the right number of private IP addresses - as many as there are
# Traffic IPs assigned to all TIP Groups
#
# Sample output we're working on:
# ip-10-8-2-115:~# echo 'TrafficIPGroups.getTrafficIPGroupNames' | /usr/bin/zcli 
# ["Web VIP"]
# ip-10-8-2-115:~# echo 'TrafficIPGroups.getIPAddresses "Web VIP"' | /usr/bin/zcli 
# ["13.54.192.46","54.153.152.253"]
#
# Get configured TIP Groups
tipArray=( )
zresponse=$(echo 'TrafficIPGroups.getTrafficIPGroupNames' | /usr/bin/zcli)
if [[ "$?" == 0 ]]; then
    IFS='[]",' read -r -a tmpArray <<< "$zresponse"
    for i in "${!tmpArray[@]}"; do
        if [[ ${tmpArray[i]} != "" ]]; then
            tipArray+=( "${tmpArray[i]}" );
        fi
    done
    unset tmpArray
    s_list=$(echo ${tipArray[@]/%/,} | sed -e "s/,$//g")
    logMsg "037: Got Traffic IP groups: \"$s_list\""
else
    logMsg "038: Error getting Traffic IP Groups; perhaps none configured yet"
fi

# Iterate over TIP Groups we found; count the total number of TIPs in all of them
#
numTIPs=0
for tipGroup in "${!tipArray[@]}"; do
    zresponse=$(echo "TrafficIPGroups.getIPAddresses \"${tipArray[$tipGroup]}\"" | /usr/bin/zcli)
    if [[ "$?" == 0 ]]; then
        IFS='[]",' read -r -a tmpArray <<< "$zresponse"
        for i in "${!tmpArray[@]}"; do
            if [[ ${tmpArray[i]} != "" ]]; then
                tipIPArray+=( "${tmpArray[i]}" );
            fi
        done
        unset tmpArray
        if [[ ${#tipIPArray[*]} != 0 ]]; then
            let "numTIPs += ${#tipIPArray[*]}"
        fi
        s_list=$(echo ${tipIPArray[@]/%/,} | sed -e "s/,$//g")
        logMsg "039: Got Traffic IPs for TIP Group \"${tipArray[$tipGroup]}\": \"$s_list\"; numTIPs is now $numTIPs"
    else
        logMsg "040: Error getting Traffic IPs from TIP Group \"${tipArray[$tipGroup]}\""
    fi
done

# We would like to always have at least two secondary IPs available, to ensure
# configuration for a typical scenario with 2 x TIPs works successfully.
# If we don't do this, vADC cluster may sit in "Error" state until the next housekeeper run
# after a first TIP Group has been created.
#
# AWS Docs reference on instance types and secondary IPs:
# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI
#
if [[ $numTIPs < 2 ]]; then
    numTIPs=2
fi

# Get a JSON for ourselves in $resFName
safe_aws ec2 describe-instances --region $region \
    --instance-id $myInstanceID --output json

myLocalIP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# What's the ENI ID of my eth0? We'll need it to add/remove private IPs.
# Find .NetworkInterfaces where .PrivateIpAddresses[].PrivateIpAddress = $myLocalIP,
# then extract the .NetworkInterfaceId
eniID=$(cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
    select(.PrivateIpAddresses[].PrivateIpAddress==\"$myLocalIP\") | \
    .NetworkInterfaceId")

# Let's see how many secondary IP addresses I already have
declare -a myPrivateIPs
myPrivateIPs=( $(cat $resFName | \
    jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
    select(.NetworkInterfaceId==\"$eniID\") | \
    .PrivateIpAddresses[] | \
    select(.Primary==false) | \
    .PrivateIpAddress") )

# Compare the number of my secondary private IPs with the number of TIPs in my cluster
if [[ "${#myPrivateIPs[*]}" != "$numTIPs" ]]; then
    # There's a difference; we need to adjust
    logMsg "041: Need to adjust the number of private IPs. Have: ${#myPrivateIPs[*]}, need: $numTIPs"
    if (( $numTIPs > ${#myPrivateIPs[*]} )); then
        # Need to add IPs
        let "delta = $numTIPs - ${#myPrivateIPs[*]}"
        logMsg "042: Adding $delta private IPs to ENI $eniID"
        safe_aws ec2 assign-private-ip-addresses \
            --region $region \
            --network-interface-id $eniID \
            --secondary-private-ip-address-count $delta
    else
        # Need to remove IPs
        # First let's find out which one(s) don't have EIP associated, as we can only remove those.
        declare -a myFreePrivateIPs
        myFreePrivateIPs=( $(cat $resFName | \
            jq -r ".Reservations[].Instances[].NetworkInterfaces[] | \
            select(.NetworkInterfaceId==\"$eniID\") | \
            .PrivateIpAddresses[] | \
            select(.Primary==false) | \
            select (.Association.PublicIp==null) | \
            .PrivateIpAddress") )
        let "delta = ${#myPrivateIPs[*]} - $numTIPs"
        # If we need to remove more IPs than we have without EIPs, then only remove those we can
        if (( $delta > ${#myFreePrivateIPs[*]} )); then
            logMsg "043: Need to delete $delta, but can only do ${#myFreePrivateIPs[*]}; the rest is tied with EIPs."
            delta=${#myFreePrivateIPs[*]}
        fi
        for ((i=0; i < $delta; i++)); do
            num=$RANDOM
            let "num %= ${#myFreePrivateIPs[*]}"
            ipToDelete=${myFreePrivateIPs[$num]}
            let "j = i + 1"
            logMsg "044: Deleting IP $j of $delta - $ipToDelete from ENI $eniID"
            # Not using "safe_aws" here; it's OK to fail - we'll just retry the next time round.
            aws ec2 unassign-private-ip-addresses \
                --region $region \
                --network-interface-id $eniID \
                --private-ip-addresses $ipToDelete 2>>$awscliLogF
            sleep 3
        done
    fi
    logMsg "045: Done adjusting private IPs."
else
    logMsg "046: No need to adjust private IPs."
fi

exit 0
