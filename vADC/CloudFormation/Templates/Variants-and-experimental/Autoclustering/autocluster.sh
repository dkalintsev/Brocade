#!/bin/bash
#
# This script is customised on deploy by cfn-init
# We expect the following vars passed in:
# StackName = AWS::StackName
# AdminPass = AdminPass
# Region = AWS::Region
# Verbose = "Yes|No" - this controls whether we print extensive log messages as we go.
export PATH=$PATH:/usr/local/bin

clusterID="{{StackName}}-vADC-Cluster"
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

myInstanceID=$(curl http://169.254.169.254/latest/meta-data/instance-id)

logMsg () {
    if [[ "$verbose" =~ ^[Yy] ]]; then
        ts=$(date -u +%FT%TZ)
        echo "$ts $0[$$]: $*" >> /tmp/autocluster.log
    fi
}

# Set tag on $myInstanceID
# $1 = tag
# $2 = value
#
setTag () {
    logMsg "002: Setting tags on $myInstanceID: \"$1:$2\""
    aws ec2 create-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1,Value=$2
    declare -a stList
    unset stList
    while [[ ${#stList[*]} == 0 ]]; do
        stList=( $(findTaggedInstances $1 $2 | grep "$myInstanceID") )
        logMsg "003: Checking tagged instances \"$1:$2\", expecting to see ourselves; got \"$stList\""
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
    aws ec2 delete-tags --region $region \
        --resources $myInstanceID \
        --tags Key=$1
    declare -a stList
    stList=( blah )
    while [[ ${#stList[*]} > 0 ]]; do
        stList=( $(findTaggedInstances $1 $2 | grep "$myInstanceID") )
        logMsg "007: Checking tagged instances \"$1:$2\", expecting NOT to see ourselves; got \"$stList\""
        if [[ ${#stList[*]} == 0 ]]; then
            logMsg "008: Tag \"$1:$2\" is gone, we're done."
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

    # No logging here, since we're returning the actual output and log will mess with it. :)
    aws ec2 describe-instances --region $region \
        --filters $filter \
        "Name=tag:$1,Values=$2" \
        | jq -r ".Reservations[] | .Instances[] | .InstanceId"
}

# Returns private IP of an instance by instance-id
# $1 instance-id
#
getInstanceIP () {
    aws ec2 describe-instances --region $region \
    --instance-id $1 \
    | jq -r ".Reservations[] | .Instances[] | .NetworkInterfaces[] | .PrivateIpAddress"
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
            list=( $(findTaggedInstances $1 $2) )
            if [[ ${#list[*]} > 0 ]]; then
                s_list="${list[0]}"
                for i in $(seq 1 $((${#list[*]}-1)) ); do
                    s_list="$s_list, ${list[$i]}";
                done
                logMsg "011: Found some: \"$s_list\", sleeping..."
                sleep 5
            fi
        done
        # once there aren't any, tag ourselves
        logMsg "012: Tagging ourselves: \"$1:$2\""
        setTag $1 $2
        list=( blah )
        # check if there are more than one including us
        while [[ ${#list[*]} > 0 ]]; do
            list=( $(findTaggedInstances $1 $2 | grep -v "$myInstanceID") )
            s_list="${list[0]}"
            for i in $(seq 1 $((${#list[*]}-1)) ); do
                s_list="$s_list, ${list[$i]}";
            done
            logMsg "013: Looking for others with the same tags, found: \"$s_list\""
            if [[ ${#list[*]} > 0 ]]; then
                # there's someone else - clash
                logMsg "014: Clash detected, calling delTag: \"$1\" \"$2\""
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
    delTag "$electionTag" "$statusForming"
    getLock "$electionTag" "$statusForming"
    logMsg "018: Election tag locked; checking if anyone sneaked past us into $statusActive"
    declare -a list
    # Check if there's anyone already $statusActive
    list=( $(findTaggedInstances $stateTag $statusActive) )
    if [[ ${#list[*]} > 0 ]]; then
        # Clear $statusForming and bail
        logMsg "019: Looks like someone beat us to it somehow. Bailing on elections."
        delTag "$electionTag" "$statusForming"
        return 1
    else
        # Ok, looks like we're cler to proceed
        logMsg "020: We won elections, setting ourselves $statusActive"
        setTag "$stateTag" "$statusActive"
        delTag "$electionTag" "$statusForming"
        return 0        
    fi
}

joinCluster () {
    logMsg "021: Starting cluster join.."
    delTag "$stateTag" "$statusJoining"
    declare -a list
    # Are there is/are instances where $stateTag == $statusActive
    # There should be since this is how we got here, but let's make double sure.
    list=( $(findTaggedInstances $stateTag $statusActive) )
    s_list="${list[0]}"
    for i in $(seq 1 $((${#list[*]}-1)) ); do
        s_list="$s_list, ${list[$i]}";
    done
    logMsg "022: Querying $statusActive vTMs; got: \"$s_list\""
    if [[ ${#list[*]} > 0 ]]; then
        logMsg "023: Getting lock on $stateTag $statusJoining"
        getLock "$stateTag" "$statusJoining"
        num=$RANDOM
        let "num %= ${#list[*]}"
        instanceToJoin=${list[$num]}
        node=$(getInstanceIP $instanceToJoin)
        logMsg "024: Picked the node to join: \"$node\""
        logMsg "025: Creating and running cluster join script"
        # doing join
        rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
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
        $tmpf
        if [[ "$?" != "0" ]]; then
            logMsg "026: Some sort of error happened, let's keep trying.."
            rm -f $tmpf
            return 1
        else
            logMsg "027: All seems to be good. Releasing lock on tag $statusJoining."
            rm -f $tmpf
            delTag "$stateTag" "$statusJoining" 
            return 0
        fi
    else
        # This should not have happened, but whatevs..
        logMsg "028: This should not have happened - entered func to join cluster, found nobody to join."
        return 1
    fi
}

# Before we begin, let's check if we're already in $statusActive state, so as not to waste time.

declare -a list
list=( $(findTaggedInstances $stateTag $statusActive | grep $myInstanceID) )
s_list="${list[0]}"
for i in $(seq 1 $((${#list[*]}-1)) ); do
    s_list="$s_list, ${list[$i]}";
done
logMsg "029: Checking if we are already $statusActive; got: \"$s_list\""
if [[ ${#list[*]} > 0 ]]; then
    logMsg "030: Looks like we've nothing more to do; exiting."
    exit 0
else
    logMsg "031: Welp, we've got work to do."
fi

while true; do
    # Main loop
    logMsg "032: Entering main loop.."
    declare -a list
    # Is/are there are instances where $stateTag == $statusActive?
    list=( $(findTaggedInstances $stateTag $statusActive) )
    s_list="${list[0]}"
    for i in $(seq 1 $((${#list[*]}-1)) ); do
        s_list="$s_list, ${list[$i]}";
    done
    logMsg "033: Checking for $statusActive vTMs; got: \"$s_list\""
    if [[ ${#list[*]} > 0 ]]; then
        logMsg "034: There are active node(s), starting join process."
        joinCluster
        if [[ "$?" == "0" ]]; then
            logMsg "035: Join successful, setting ourselves $statusActive, and we're done."
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
