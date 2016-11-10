#!/bin/bash

#
# Variables
#
# Pattern to match when querying AWS for vRouter AMIs
#
vRAMI='*vyatta-ami_*'
#
# There may be many versions available; how many freshest ones to include?
#
Versions='3'
#
OPTIND=1
force=0

function show_help {
	printf "This script queries AWS for AMI IDs of Brocade vRouter 5600 in all regions, and prints the respective\n"
	printf "\"Parameters\" and \"Mappings\" sections for CloudFormation template.\n\n"
	printf "When run, script checks for existence of per-region cached result files and re-uses contents, unless\n"
	printf "the script was executed with the \"-f\" parameter, in which case AWS is re-queried (takes long time).\n\n"
	printf "Usage: $0 [-f]\n\n"
}

while getopts "h?f" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    f)  force=1
        ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

declare -a regions
declare -a versions

regions=( $(aws --region ap-southeast-2 ec2 describe-regions | awk -F "\"" ' /RegionName/ { print $4 }') )

pos=$(( ${#regions[*]} - 1 ))
for i in $(seq 0 $pos); do
	reg=${regions[$i]}
	printf "Querying region: %s\n" $reg
	fn="vRouter-amis_"$reg"_txt"
	if [[ -a "$fn" && "$force" == "1" ]]; then
		echo "Force parameter was specified; deleting and re-creating \"$fn\" from AWS."
		rm -f "$fn"
	fi
	if [[ -a "$fn" ]]; then
		echo "Cached contents found for this region; re-run this script as \"$0 -f\" to force update."
	else
		aws --region $reg ec2 describe-images --owners aws-marketplace --filters Name=name,Values="$vRAMI" | awk -F "\"" ' /"Name"/ { printf "%s_", $4 }; /"ImageId"/ { printf "%s\n", $4 }' | sed -e "s/ami_/ami:/g" -e "s/_amd/:amd/g" -e "s/_ami/:ami/g" -e "s/\.//g" -e "s/_//g" | awk -F ":" '{ printf "%s:%s\n", $2, $4 }' > "$fn"
		echo "Got $(wc -l $fn | awk '{print $1}') AMIs"
	fi
done

versions=( $(cat vRouter-amis_* | awk -F: '{print $1}' | sort -n | uniq | tail -"$Versions") )
pos1=$(( ${#versions[*]} - 1 ))

printf "\n\nCut and paste the output below into your CloudFormation template:\n"
printf "=================================================================\n\n"

printf "  \"Parameters\" : {\n"
printf "    \"vRVers\" : {\n"
printf "      \"Description\" : \"Please select vRouter version:\",\n"
printf "      \"Type\" : \"String\",\n"
printf "      \"Default\" : \"%s\",\n" ${versions[$pos1]}
printf "      \"AllowedValues\" : [\n"
for j in $(seq 0 $pos1); do
	printf "        \"%s\"" ${versions[$j]}
	if (( $j < $pos1 )); then
		printf ",\n"
	else
		printf "\n"
	fi
done
printf "      ],\n"
printf "      \"ConstraintDescription\" : \"Must be a valid vRouter version\"\n"
printf "    }\n"
printf "  }\n\n"

printf "  \"Mappings\" : {\n"
printf "    \"vRAMI\" : {\n"

for i in $(seq 0 $pos); do
	reg=${regions[$i]}
	fn="vRouter-amis_"$reg"_txt"
	if [[ -s "$fn" ]]; then
		printf "      \"%s\" : {" $reg
		pos1=$(( ${#versions[*]} - 1 ))
		for j in $(seq 0 $pos1); do
			ver=${versions[$j]}
			ami=$(egrep "$ver" "$fn" | cut -f2 -d:)
			if [[ ! -z "$ami" ]]; then
				printf " \"%s\" : \"%s\"" $ver $ami
				if (( $j < $pos1 )); then
					printf ","
				fi
			fi
		done
		if (( $i == $pos )); then
			printf " }\n"
		else
			printf " },\n"
		fi
	fi
done
printf "    }\n"
printf "  }\n"
printf "\n=================================================================\n\n"
