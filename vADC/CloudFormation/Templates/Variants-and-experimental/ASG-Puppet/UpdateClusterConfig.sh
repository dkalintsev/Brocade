#!/bin/bash
#
# This script queries AWS account for running instances of vADCs with a given
# ClusterID tag, and backend web servers with a given PoolTag.
#
# It then applies these values to the contents of cluster-config-template.pp file
# to produce the cluster-config.pp
#
# The script then checks if the newly created cluster-config.pp is any different
# to what it was before the script was run. If changes are detected, that means
# that vADC cluster config has to be updated. This may be because of changes in
# either vADC cluster members, or backend pool members. Script will signal that
# it detected changes by terminating with the exit code of 10.
#
# logMsg uses "nnn: <message>" format, where "nnn" is sequential. If you end up
# adding or removing logMsg calls in this script, run the following command to re-apply
# the sequence:
#
# perl -i -000pe 's/(logMsg "001..)/$1 . sprintf("%03d", ++$n)/ge' UpdateClusterConfig.sh
#
# If you have a better idea for debugging / traceability - open an issue or even better
# a pull request ;)

export PATH=$PATH:/usr/local/bin
logFile="/var/log/UpdateClusterConfig.log"

clusterID="{{ClusterID}}"
region="{{Region}}"
verbose="{{Verbose}}"
pool="{{Pool}}"
pool_tag="{{PoolTag}}"

# Creating temp filenames to keep lists of running and clustered instances, and delta between the two.
#
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)
resFName="/tmp/aws-out.$rand_str"
jqResFName="/tmp/jq-out.$rand_str"
awscliLogF="/var/log/UpdateClusterConfig-out.log"
changeSetF="/tmp/changeSetF.$rand_str"

# Variables
#
lockF="/tmp/UpdateClusterConfig.lock"
left_in="{\"node\":\""
right_in=":80\",\"priority\":1,\"state\":\"active\",\"weight\":1}"
work_dir="/root"
manifest_template="$work_dir/cluster-config-template.pp"
manifest="$work_dir/cluster-config.pp"
vADC1PrivateIP=""
vADCnDNS=""

# Tag for Cluster state
stateTag="ClusterState"

# Values for Cluster
statusActive="Active"

cleanup  () {
    rm -f $resFName $jqResFName
    rm -f $changeSetF
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
    logMsg "002: Found lock file, exiting."
    exit 1
fi

# We need jq, which should have been installed by now.
which jq >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "003: Looks like jq isn't installed; quiting."
    exit 1
fi

# We also need aws cli tools.
which aws >/dev/null 2>&1
if [[ "$?" != "0" ]]; then
    logMsg "004: Looks like AWS CLI tools isn't installed; quiting."
    exit 1
fi

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
            logMsg "005: safe_aws \"$*\" exceeded retry budget. Sleeping for $backoff second(s), then back to work.."
            sleep $backoff
            retries=0
            backoff=1
        fi
        aws $* > $resFName 2>>$awscliLogF
        errCode=$?
        if [[ "$errCode" != "0" ]]; then
            logMsg "006: AWS CLI returned error $errCode; sleeping for $backoff seconds.."
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

# Returns list of instances with matching tags
# $1 tag
# $2 value
# $3 optional flag to tell us we'll be looking for $clusterID
#
findTaggedInstances () {
    # We operate only on instances that are in "running" state
    #
    filter="Name=instance-state-name,Values=running"

    # if we're given tag and value, look for these; if not - just return running instances
    if [ $# -ge "2" ]; then
        filter=$filter" Name=tag:$1,Values=$2"
    fi

    if [ $# -eq "3" ]; then
        filter=$filter" Name=tag:ClusterID,Values=$clusterID"
    fi

    # Run describe-instances and make sure we get valid JSON (which includes empty file)
    safe_aws ec2 describe-instances --region $region \
        --filters $filter --output json
    cat $resFName | jq -r ".Reservations[].Instances[].InstanceId" > $jqResFName
    return 0
}

# Returns private IP of an instance by instance-id
# $1 instance-id
#
getInstanceIP () {
    safe_aws ec2 describe-instances --region $region \
        --instance-id $1 --output json
    cat $resFName | jq -r ".Reservations[].Instances[].NetworkInterfaces[].PrivateIpAddress" > $jqResFName
    return 0
}

# Returns private DNS name of an instance by instance-id
# $1 instance-id
#
getInstanceDnsName () {
    safe_aws ec2 describe-instances --region $region \
        --instance-id $1 --output json
    cat $resFName | jq -r ".Reservations[].Instances[].NetworkInterfaces[].PrivateDnsName" > $jqResFName
    return 0
}

### Main()

cleanup
touch $lockF

# Saving SHA checksum of our original $manifest for later checking
# There could be no original $manifest, which is fine too. :)
#
oldsha=$(shasum "$manifest" | awk '{print $1}')

# We need to customise cluster-config-template with the following values:
# - __vADC1PrivateIP__ => a private IP of one of the vADCs in the cluster (with tag "Active")
# - __vADCnDNS__ => list of Private DNS names for vADC nodes - "Node1.domain.com","Node2.domain.com"
# - put private IPs of EC2s tagged with $pool_tag into the basic__nodes_table for the given $pool
#
# Let's collect these values, shall we?
#
# First, let's get a list of running vADC instances that have formed cluster.
# They will have $stateTag = $statusActive

declare -a list

# Is/are there are instances where $stateTag == $statusActive?
# Mind that the parameter "ADCs" at the end of findTaggedInstances is just to flag that we're looking
# for EC2 instances tagged with "ClusterID" == $clusterID
#
findTaggedInstances $stateTag $statusActive ADCs
list=( $(cat $jqResFName | sort -rn) )
s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
logMsg "007: Checking for $statusActive vTMs; got: \"$s_list\""

# Next, let's get the private IP of the first one; that will be our vADC1PrivateIP
if [[ ${#list[*]} > 0 ]]; then
    instance=${list[0]}
    getInstanceIP $instance
    vADC1PrivateIP=$(cat $jqResFName)
    logMsg "008: Picked value for __vADC1PrivateIP__: \"$vADC1PrivateIP\""
else
    # Didn't find any active vADCs
    logMsg "009: Didn't find any active vADCs; exiting for now."
    exit 0
fi

# We still have the list of vADC EC2 InstanceIDs in the $list. Let's use that to build __vADCnDNS__
# Result should be in the format (including quotes): "host1.domain.com","host2.domain.com"
#
# Trivia: getting the last element of an array was pulled from here:
# http://stackoverflow.com/questions/1951506/bash-add-value-to-array-without-specifying-a-key
#
for instance in ${list[@]}; do
    # "for" loop here is good enough since we don't expect any spaces in the array elements
    getInstanceDnsName $instance
    dnsname=$(cat $jqResFName)
    logMsg "010: Private DNS name for Instance $instance is $dnsname"
    if [[ "${list[@]: -1}" != "$instance" ]]; then
        vADCnDNS=$vADCnDNS"\"$dnsname\","
    else
        vADCnDNS=$vADCnDNS"\"$dnsname\""
    fi
done

# We need to collect private IPs of the pool members. They are tagged with "Name" == $pool_tag
# First, let's create a list of EC2 instance IDs for these.
#
findTaggedInstances "Name" $pool_tag
list=( $(cat $jqResFName | sort -rn) )
s_list=$(echo ${list[@]/%/,} | sed -e "s/,$//g")
logMsg "011: Looking for running instances tagged with $pool_tag; got: \"$s_list\""

# Now, let's walk through the resulting list and create a Puppet manifest definition for the pool
#
declare -a IPlist
unset IPlist
nodes=""

if [[ ${#list[*]} == 0 ]]; then
    # Didn't find any running backend pool members; let's set our pool to 127.0.0.1
    logMsg "012: Didn't find any running backend pool instances; will set the pool to 127.0.0.1:80"
    nodes="$left_in""127.0.0.1""$right_in"
else
    for instance in ${list[@]}; do
        # "for" loop here is good enough since we don't expect any spaces in the array elements
        getInstanceIP $instance
        IP=$(cat $jqResFName)
        logMsg "013: Private IP of Instance $instance is $IP"
        a="$left_in""$IP""$right_in"
        if [[ "${list[@]: -1}" != "$instance" ]]; then
            nodes="$nodes""$a"","
        else
            nodes="$nodes""$a"
        fi
    done
fi

# Ok, we're ready with all the variables we need. We'll create $manifest from $manifest_template
# customised with the values we've got.
#
# Edit the current manifest:
# awk to change \n to |, then sed to search for our Pool name, replace
# everything in "[]" against brocadevtm::pools with what we've cooked up just above,
# as well as __vADC1PrivateIP__ and __vADCnDNS__, and finally change | back to \n
#
cat "$manifest_template" | awk 1 ORS="|" \
  | sed -e "s/__vADC1PrivateIP__/$vADC1PrivateIP/g" \
  | sed -e "s/\(.*brocadevtm::pools { '$pool':.*basic__nodes_table                       => '\)\(\[[^]]*\]\)\(.*\)/\1\[$nodes\]\3/g" \
  | sed -e "s/__vADCnDNS__/$vADCnDNS/g" \
  | tr '|' '\n' > "$changeSetF"

# Some awk versions add an extra \n to the end of file.
# Let's deal with that:
#
man_len=$(wc -l "$manifest" | awk '{print $1}')
tmp_len=$(wc -l "$changeSetF" | awk '{print $1}')
if (( tmp_len == man_len+1 )); then
    # Yep, we're dealing with one of those; let's fix it.
    sed -i -e '$d' "$changeSetF"
fi

if [[ -s "$changeSetF" ]]; then
    cat "$changeSetF" > "$manifest"
    rm -f "$changeSetF"
else
    logMsg "014: Edit resulted in an empty file for some reason. Not creating $manifest."
    rm -f "$changeSetF"
    exit 1
fi

newsha=$(shasum "$manifest" | awk '{print $1}')

if [[ "$newsha" != "$oldsha" ]]; then
    logMsg "015: File changed; need to update"
    # Yeah, I know - error code "10" is arbitrary. Let me know if you have a better idea.
    exit 10
else
    logMsg "016: No changes needed."
    exit 0
fi