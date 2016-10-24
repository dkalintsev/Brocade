#!/bin/bash
#
# This script is customised during vADC instance deployment by cfn-init
# Please see example usage in the CloudFormation template:
# https://github.com/dkalintsev/Brocade/blob/master/vADC/CloudFormation/Templates/Variants-and-experimental/Autoclustering/vADC-Deploy-ASG.template
#
# The purpose of this script is to form a new vADC cluster or join an existing one.
#
# We expect the following vars passed in:
# ClusterID = AWS EC2 tag used to find vADC instances in our cluster
# AdminPass = AdminPass
# Region = AWS::Region
# Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.
#
# vADC instances running this script will need to have an IAM Role with the Policy allowing:
# - ec2:DescribeInstances
# - ec2:CreateTags
# - ec2:DeleteTags
# 
export PATH=$PATH:/usr/local/bin
logFile="/var/log/autoscluster.log"

clusterID="{{ClusterID}}"
adminPass="{{AdminPass}}"
region="{{Region}}"
verbose="{{Verbose}}"

# Tags for Cluster and Elections
stateTag="ClusterState"
electionTag="ElectionState"

# Values for Cluster
statusActive="Active"
statusJoining="Joining"

# Value for Elections
statusForming="Forming"

# Random string for /tmp files
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
resFName="/tmp/aws-out.$rand_str"
jqResFName="/tmp/jq-out.$rand_str"

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
    logMsg "040: Looks like AWS CLI tools isn't installed; quiting."
    exit 1
fi

# When ASG starts multiple vADC instances, it's probably better to pace ourselves out.
backoff=$RANDOM
let "backoff %= 30"
sleep $backoff

myInstanceID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

cleanup  () {
    rm -f $resFName $jqResFName
}

trap cleanup EXIT

logMsg () {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >> $logFile
    fi
}

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
            logMsg "044: safe_aws \"$*\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff            
            retries=0
            backoff=1
        fi
        aws $* > $resFName 2>&1
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "043: AWS CLI returned error $errCode; sleeping for $backoff seconds.."
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
    logMsg "002: Setting tags on $myInstanceID: \"$1:$2\""
    safe_aws ec2 create-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1,Value=$2
    # Check if I can find myself by the newly applied tag
    declare -a stList
    unset stList
    while [[ ${#stList[*]} == 0 ]]; do
        findTaggedInstances $1 $2
        stList=( $(cat $jqResFName | grep "$myInstanceID") )
        logMsg "003: Checking tagged instances \"$1:$2\", expecting to see $myInstanceID; got \"$stList\""
        if [[ ${#stList[*]} == 1 ]]; then
            logMsg "004: Found us, we're done."
        else
            logMsg "005: Not yet; sleeping for a bit."
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
    logMsg "006: Deleting tags: \"$1:$2\""
    safe_aws ec2 delete-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1
    # Check if we don't come up when searching for the tag, i.e., tag is gone
    declare -a stList
    stList=( blah )
    while [[ ${#stList[*]} > 0 ]]; do
        findTaggedInstances $1 $2
        stList=( $(cat $jqResFName | grep "$myInstanceID") )
        logMsg "007: Checking tagged instances \"$1:$2\", expecting NOT to see $myInstanceID; got \"$stList\""
        if [[ ${#stList[*]} == 0 ]]; then
            logMsg "008: Tag \"$1:$2\" is not there, we're done."
        else
            logMsg "009: Not yet; sleeping for a bit."
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
    cat $resFName | jq -r ".Reservations[] | .Instances[] | .InstanceId" > $jqResFName
    return 0
}

# Returns private IP of an instance by instance-id
# $1 instance-id
#
getInstanceIP () {
    safe_aws ec2 describe-instances --region $region \
        --instance-id $1 --output json
    cat $resFName | jq -r ".Reservations[] | .Instances[] | .NetworkInterfaces[] | .PrivateIpAddress" > $jqResFName
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
        # Get a list of instances with $stateTag = $tag
        # if there are any, wait 5 seconds, then retry until there are none
        while [[ ${#list[*]} > 0 ]]; do
            logMsg "010: Looping until there's no instance matching \"$1:$2\""
            findTaggedInstances $1 $2
            list=( $(cat $jqResFName | grep -v $myInstanceID) )
            if [[ ${#list[*]} > 0 ]]; then
                s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
                logMsg "011: Found some: \"$s_list\", sleeping..."
                sleep 5
            fi
        done
        # Do we already have the tag by chance?
        list=( $(cat $jqResFName | grep "$myInstanceID") )
        if [[ ${#list[*]} == 1 ]]; then
            logMsg "042: We already have that tag, returning."
            return 0
        fi        
        # once there aren't any, tag ourselves
        logMsg "012: Tagging ourselves: \"$1:$2\""
        setTag $1 $2
        list=( blah )
        # check if there are other tagged instances who managed to beat us to it
        while [[ ${#list[*]} > 0 ]]; do
            findTaggedInstances $1 $2
            list=( $(cat $jqResFName | grep -v "$myInstanceID") )
            s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
            logMsg "013: Looking for others with the same tags, found: \"$s_list\""
            if [[ ${#list[*]} > 0 ]]; then
                # there's someone else - clash
                logMsg "014: Clash detected, calling delTag: \"$1:$2\""
                delTag $1 $2
                backoff=$RANDOM
                let "backoff %= 25"
                # do random backoff, then bail to the mail while().
                logMsg "015: Backing off for $backoff seconds"
                sleep $backoff
                unset list
            else
                # lock obtained; we're done here.
                logMsg "016: Got our lock, returning."
                return 0
            fi
        done
    done
}

runElections () {
    # Obtain a lock on $statusForming
    logMsg "017: Starting elections; trying to get lock on tag $electionTag with $statusForming"
    # Just in case - if there was previous unsuccessful run
    getLock "$electionTag" "$statusForming"
    logMsg "018: Election tag locked; checking if anyone sneaked past us into $statusActive"
    declare -a list
    # Check if there's anyone already $statusActive
    findTaggedInstances $stateTag $statusActive
    list=( $(cat $jqResFName) )
    if [[ ${#list[*]} > 0 ]]; then
        # Clear $statusForming and bail
        logMsg "019: Looks like someone beat us to it somehow. Bailing on elections."
        delTag $electionTag $statusForming
        return 1
    else
        # Ok, looks like we're clear to proceed
        logMsg "020: We won elections, setting ourselves $statusActive"
        setTag "$stateTag" "$statusActive"
        delTag "$electionTag" "$statusForming"
        return 0
    fi
}

# Join the cluster. Prerequisites for this func:
# 1. Main loop detected there's an instance in $statusActive
# 2. $jqResFName has the list of $statusActive instances
#
joinCluster () {
    logMsg "021: Starting cluster join.."
    declare -a list
    # Are there instances where $stateTag == $statusActive?
    # There should be since this is how we got here, but let's make double sure.
    # Main loop alredy did findTaggedInstances, so let's reuse result.
    list=( $(cat $jqResFName) )
    logMsg "023: Getting lock on $stateTag $statusJoining"
    getLock "$stateTag" "$statusJoining"
    num=$RANDOM
    let "num %= ${#list[*]}"
    instanceToJoin=${list[$num]}
    node=$(getInstanceIP $instanceToJoin)
    logMsg "024: Picked the node to join: \"$node\""
    logMsg "025: Creating and running cluster join script"
    # doing join
    tmpf="/tmp/dojoin.$rand_str"
    rm -f $tmpf
    cat > $tmpf << EOF
#!/bin/sh

ZEUSHOME=/opt/zeus
export ZEUSHOME=/opt/zeus
exec \$ZEUSHOME/perl/miniperl -wx \$0 \${1+"\$@"}

#!perl -w
#line 9

BEGIN {
    unshift @INC
        , "\$ENV{ZEUSHOME}/zxtm/lib/perl"
        , "\$ENV{ZEUSHOME}/zxtmadmin/lib/perl"
        , "\$ENV{ZEUSHOME}/perl"
}

use Zeus::ZXTM::Configure;

MAIN: {

    my \$clusterTarget = '$node:9090';
    my %certs = Zeus::ZXTM::Configure::CheckSSLCerts( [ \$clusterTarget ] );
    my \$ret = Zeus::ZXTM::Configure::RegisterWithCluster (
        "admin",
        "$adminPass",
        [ \$clusterTarget ],
        undef,
        { \$clusterTarget => \$certs{\$clusterTarget}->{fp} },
        "Yes",
        undef,
        "Yes"
    );

    if( \$ret == 0 ) {
        exit(1);
    }
}
EOF
    chmod +x $tmpf
    sleep 30
    $tmpf
    if [[ "$?" != "0" ]]; then
        logMsg "026: Some sort of error happened, let's keep trying.."
        rm -f $tmpf
        return 1
    else
        logMsg "027: Join operation successful, returning to the main loop."
        rm -f $tmpf
        return 0
    fi
}

# Sanity check: can we find ourselves in "running" state?
#

findTaggedInstances
declare -a stList
stList=( $(cat $jqResFName | grep "$myInstanceID") )
if [[ ${#stList[*]} == 0 ]]; then
    logMsg "041: Cant't seem to be able to find ourselves running; did you set ClusterID correctly? I have: \"$clusterID\". Bailing."
    exit 1
fi

# Let's check if we're already in $statusActive state, so as not to waste time.
#
findTaggedInstances $stateTag $statusActive
declare -a list
list=( $(cat $jqResFName | grep $myInstanceID) )
s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
logMsg "029: Checking if we are already $statusActive; got: \"$s_list\""
if [[ ${#list[*]} > 0 ]]; then
    logMsg "030: Looks like we've nothing more to do; exiting."
    exit 0
else
    logMsg "031: Welp, we've got work to do."
fi

logMsg "032: Entering main loop.."
while true; do
    # Main loop
    declare -a list
    # Is/are there are instances where $stateTag == $statusActive?
    findTaggedInstances $stateTag $statusActive
    list=( $(cat $jqResFName) )
    s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
    logMsg "033: Checking for $statusActive vTMs; got: \"$s_list\""
    if [[ ${#list[*]} > 0 ]]; then
        logMsg "034: There are active node(s), starting join process."
        joinCluster
        if [[ "$?" == "0" ]]; then
            logMsg "035: Join successful, setting ourselves $statusActive.."
            setTag "$stateTag" "$statusActive"
            exit 0
        else
            logMsg "036: Join failed; returning to the main loop."
        fi
    else
        logMsg "037: No active cluster members; starting elections"
        runElections
        if [[ "$?" == "0" ]]; then
            logMsg "038: Won elections, we're done here."
            exit 0
        else
            logMsg "039: Lost elections; returning to the main loop."
        fi
    fi    
done
