#!/bin/bash
#
# This script is customised during vADC instance deployment by cfn-init
# Please see example usage in the CloudFormation template:
# https://github.com/dkalintsev/Brocade/blob/master/vADC/CloudFormation/Templates/Variants-and-experimental/Autoclustering/vADC-Deploy-ASG.template
#
# The purpose of this script is to perform housekeeping on a running vADC cluster:
# - Remove vADC nodes that aren't in "running" state
# - Make sure there's an A record in Route53 for each vADC's public IP, if "{{vADCFQDN}}" is specified
#
# We expect the following vars passed in:
# ClusterID = AWS EC2 tag used to find vADC instances in our cluster
# AdminPass = AdminPass
# Region = AWS::Region
# Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.
# vADCFQDN = "[FQDN]" - optional FQDN for vADC cluster, maintained by Route53
#
# vADC instances running this script will need to have an IAM Role with the Policy allowing:
# - ec2:DescribeInstances
# - ec2:CreateTags
# - ec2:DeleteTags
#
export PATH=$PATH:/usr/local/bin
logFile="/var/log/housekeeper.log"
configDir="/opt/zeus/zxtm/conf/zxtms"
configSync="/opt/zeus/zxtm/bin/replicate-config"

clusterID="{{ClusterID}}"
adminPass="{{AdminPass}}"
region="{{Region}}"
verbose="{{Verbose}}"
MyFQDN="{{vADCFQDN}}"

# Tag for Housekeeping
housekeeperTag="HousekeepingState"

# Value for when running Housekeeping
statusWorking="Working"

if [[ "$verbose" == "" ]]; then
    # there's no such thing as too much logging ;)
    verbose="Yes"
fi

# We need jq, which should have been installed by now.
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "001: Looks like jq isn't installed; quiting."
    exit 1
fi

# We also need aws cli tools.
which aws >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "002: Looks like AWS CLI tools isn't installed; quiting."
    exit 1
fi

myInstanceID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

logMsg () {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >> $logFile
    fi
}

# Set tag on $myInstanceID
# $1 = tag
# $2 = value
#
setTag () {
    logMsg "003: Setting tags on $myInstanceID: \"$1:$2\""
    aws ec2 create-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1,Value=$2
    declare -a stList
    unset stList
    while [[ ${#stList[*]} == 0 ]]; do
        stList=( $(findTaggedInstances $1 $2 | grep "$myInstanceID") )
        logMsg "004: Checking tagged instances \"$1:$2\", expecting to see ourselves; got \"$stList\""
        if [[ ${#stList[*]} == 1 ]]; then
            logMsg "005: Found us, we're done."
        else
            logMsg "006: Not yet; sleeping for a bit."
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
    logMsg "007: Deleting tags: \"$1:$2\""
    aws ec2 delete-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1
    declare -a stList
    stList=( blah )
    while [[ ${#stList[*]} > 0 ]]; do
        stList=( $(findTaggedInstances $1 $2 | grep "$myInstanceID") )
        logMsg "008: Checking tagged instances \"$1:$2\", expecting NOT to see ourselves; got \"$stList\""
        if [[ ${#stList[*]} == 0 ]]; then
            logMsg "009: Tag \"$1:$2\" is not there, we're done."
        else
            logMsg "010: Not yet; sleeping for a bit."
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

    # No logging here, since we're returning the actual output and log will mess with it. :)
    aws ec2 describe-instances --region $region \
        --filters $filter \
        | jq -r ".Reservations[] | .Instances[] | .InstanceId"
}

# function getLock - makes sure we're the only running instance with the
# $stateTag == Tag passed to us as function parameter
#
# $1 & $2 = tag & value to lock on for myInstanceID
getLock () {
    declare -a list
    while true; do
        list=( blah )
        # Get a list of instances with $stateTag = $tag
        # if there are any, wait 5 seconds, then retry until there are none
        while [[ ${#list[*]} > 0 ]]; do
            logMsg "011: Looping until there's no instance matching \"$1:$2\""
            list=( $(findTaggedInstances $1 $2) )
            if [[ ${#list[*]} > 0 ]]; then
                s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
                logMsg "012: Found some: \"$s_list\", sleeping..."
                sleep 5
            fi
        done
        # once there aren't any, tag ourselves
        logMsg "013: Tagging ourselves: \"$1:$2\""
        setTag $1 $2
        list=( blah )
        # check if there are more than one including us
        while [[ ${#list[*]} > 0 ]]; do
            list=( $(findTaggedInstances $1 $2 | grep -v "$myInstanceID") )
            s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
            logMsg "014: Looking for others with the same tags, found: \"$s_list\""
            if [[ ${#list[*]} > 0 ]]; then
                # there's someone else - clash
                logMsg "015: Clash detected, calling delTag: \"$1\" \"$2\""
                delTag $1 $2
                backoff=$RANDOM
                let "backoff %= 25"
                # do random backoff, then bail to the mail while().
                logMsg "016: Backing off for $backoff seconds"
                sleep $backoff
                unset list
            else
                # lock obtained; we're done here.
                logMsg "017: Got our lock, returning."
                return 0
            fi
        done
    done
}

# First, do random sleep to avoid race with other cluster nodes, since we're running from cron.
#
backoff=$RANDOM
let "backoff %= 25"
logMsg "018: Running initial backoff for $backoff seconds"
sleep $backoff

declare -a list
list=( $(findTaggedInstances $housekeeperTag $statusWorking | grep -v $myInstanceID) )
s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
logMsg "019: Checking if an other node is already running Housekeeping; got: \"$s_list\""
if [[ ${#list[*]} > 0 ]]; then
    logMsg "020: Yep, somebody beat us to it. Exiting."
    exit 0
else
    logMsg "021: Ok, let's get to work."
fi

logMsg "022: Getting lock on $statusWorking.."
getLock $housekeeperTag $statusWorking

# Creating temp filenames to keep lists of running and clustered instances, and delta between the two.
#
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
runningInstF="/tmp/running.$rand_str"
clusteredInstF="/tmp/clustered.$rand_str"
deltaInstF="/tmp/delta.$rand_str"
filesF="/tmp/files.$rand_str"
rm -f $runningInstF $clusteredInstF $deltaInstF $filesF

# List running instances in our vADC cluster
logMsg "023: Checking running instances.."
findTaggedInstances | sort -rn > $runningInstF
# Go to cluster config dir, and look for instanceIDs in config files there
logMsg "024: Checking clustered instances.."
cd $configDir
grep -i instanceid * | awk '{print $2}' | sort -rn | uniq > $clusteredInstF
# Compare the two, looking for lines that are present in the cluster config but missing in running list
logMsg "025: Comparing list of running and clustered instances.."
diff $clusteredInstF $runningInstF | awk '/^</ { print $2 }' > $deltaInstF

if [[ -s $deltaInstF ]]; then
    # There is some delta - $deltaInstF isn't empty
    declare -a list
    list=( $(cat $deltaInstF) )
    s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
    logMsg "026: Delta detected - need to do clean up the following instances: $s_list."
    for instId in ${list[@]}; do
        grep -l "$instId" * >> $filesF 2>/dev/null
    done
    if [[ -s $filesF ]]; then
        svIFS=IFS
        IFS=$(echo -en "\n\b")
        files=( $(cat $filesF) )
        IFS=svIFS
        for file in ${files[@]}; do
            logMsg "027: Deleting $file.."
            rm -f "$file"
        done
        logMsg "028: Synchronising cluster state.."
        $configSync
        logMsg "029: All done, exiting."
    else
        logMsg "030: Hmm, can't find config files with matching instanceIDs; maybe somebody deleted them already. Exiting."
    fi
    delTag $housekeeperTag $statusWorking
    rm -f $runningInstF $clusteredInstF $deltaInstF $filesF
    exit 0
else
    logMsg "031: No delta, exiting."
    delTag $housekeeperTag $statusWorking
    rm -f $runningInstF $clusteredInstF $deltaInstF $filesF
    exit 0    
fi
