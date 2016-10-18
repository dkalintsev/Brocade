#!/bin/bash
#
# Defaults for parameters
#
region="ap-southeast-2"
pool="WebPool"
pool_tag="pup-WebServer"
#
# Variables
#
left_in="{\"node\":\""
right_in=":80\",\"priority\":1,\"state\":\"active\",\"weight\":1}"
work_dir="/root"
manifest="example.pp"
rand_str=$(cat /dev/urandom | env LC_CTYPE=C tr -cd 'a-f0-9' | head -c 10)

OPTIND=1
debug=0

function show_help {
	printf "\nThis script will find out IPs of running EC2 instances tagged with the specified Tag\n"
    printf "and update the specified ::pools in the Puppet manifest file $work_dir/$manifest accordingly.\n"
    printf "\nThe script will indicate through an exit code whether changes were made - 0 for no, 10 for yes.\n"
    printf "\nRequired parameters:\n\t-r <region> : Region where we're running\n"
    printf "\t-p <pool name> : Name of the pool in the Manifest file (must exist)\n"
    printf "\t-t <pool tag> : unique tag to find pool EC2 instances by\n\n"
    printf "Instance running this script needs to have an IAM role with Policy allowing ec2:DescribeInstances\n\n"
}

while getopts "h?dr:p:t:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    d)  debug=1
        ;;
    r)  region=$OPTARG
        ;;
    p)  pool=$OPTARG
        ;;
    t)  pool_tag=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

if [[ "$region" == "" || "$pool" == "" || "$pool_tag" == "" || "$rand_str" == "" ]]; then
    echo "Error: One of the required parameters is empty"
    echo "Region: \"$region\""
    echo "Pool: \"$pool\""
    echo "Pool Tag: \"$pool_tag\""
    echo "Random Str: \"$rand_str\""
    exit 1
fi

if [[ "$debug" == "0" ]]; then
    if [[ ! -d "$work_dir" ]]; then
        echo "Work directory \"$work_dir\" doesn't exist or inaccessible, exiting."
        exit 1
    fi
    cd "$work_dir"
    which jq >/dev/null 2>&1
    if [[ "$?" != "0" ]]; then
        echo "Looks like we don't have jq installed; quitting'"
        exit 1
    fi
fi

if [[ ! -f "$manifest" ]]; then
	echo "Can't find \"$manifest\"; exiting"
	exit 1
fi

# Saving SHA checksum for later checking
oldsha=$(shasum "$manifest" | awk '{print $1}')

declare -a IPs

if [[ "$debug" == "0" ]]; then
    # Look up running instances with the "Name" Tag matching $pool_tag, use jq to extract their IPs
    # Sort at the end, in case AWS returns the same results in different order which shouldn't trigger update
    IPs=( $(aws ec2 describe-instances --region $region \
        --filters "Name=tag:Name,Values=$pool_tag" \
        "Name=instance-state-name,Values=running" \
        | jq -r ".Reservations[] | .Instances[] | .NetworkInterfaces[] | .PrivateIpAddress" \
        | sort -rn) )
else
    # We're in debug mode; just set the array to two dummy IPs
    IPs=( $(printf "%s\n%s\n" "1.1.1.1" "2.2.2.2" ) )
fi
# After the above, the $IPs is the list of our backend pool servers' IPs 

# Build up the list of pool servers in Puppet manifest format
nodes=""
pos1=$(( ${#IPs[*]} - 1 ))
for j in $(seq 0 $pos1); do
	a="$left_in""${IPs[$j]}""$right_in"
	if (( $j < $pos1 )); then
		nodes="$nodes""$a"","
	else
		nodes="$nodes""$a"
	fi
done

# Edit the current manifest:
# awk to change \n to |, then sed to search for our Pool name, replace
# everything in "[]" against brocadevtm::pools with what we've cooked up just above,
# and finally change | back to \n
#
tmpf="$manifest.$rand_str"
cat "$manifest" | awk 1 ORS="|" \
  | sed -e "s/\(.*brocadevtm::pools { '$pool':.*basic__nodes_table                       => '\)\(\[[^]]*\]\)\(.*\)/\1\[$nodes\]\3/g" \
  | tr '|' '\n' > "$tmpf"

# Some awk versions add an extra \n to the end of file.
# Let's deal with that:
#
man_len=$(wc -l "$manifest" | awk '{print $1}')
tmp_len=$(wc -l "$tmpf" | awk '{print $1}')
if (( tmp_len == man_len+1 )); then
    # Yep, we're dealing with one of those; let's fix it.
    sed -i -e '$d' "$tmpf"
fi

if [[ -s "$tmpf" ]]; then
    cat "$tmpf" > "$manifest"
    rm -f "$tmpf"
else
    echo "Edit resulted in an empty file for some reason."
    echo "nodes var was \"$nodes\". Leaving $manifest unchanged."
    rm -f "$tmpf"
    exit 1
fi

newsha=$(shasum "$manifest" | awk '{print $1}')

if [[ "$newsha" != "$oldsha" ]]; then
    echo "File changed; need to update"
    # Yeah, I know - error code "10" is arbitrary. Let me know if you have a better idea.
    exit 10
else
    echo "No changes needed"
    exit 0
fi
