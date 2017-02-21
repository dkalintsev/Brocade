#!/bin/bash

#
# Variables
#
# Pattern to match when querying AWS for vRouter AMIs
#
vADCAMI='*stingray-traffic-manager-*,*brocade-virtual-traffic-manager*'
#
# Pattern to match the vADC AMI SKU Type; "STM-DEV" by default.
# At the time of writing, I can see the following SKUs:
#
# STM-DEV
# STM-CSUB-4000-L-SAF-64-bw
# STM-CSUB-4000-L-64-bw-5gbps
# STM-CSUB-2000-L-SAF-STX-64
# STM-CSUB-2000-L-SAF-64-bw
# STM-CSUB-2000-L-64-bw-1gbps
# STM-CSUB-1000-M-SAF-STX-64
# STM-CSUB-1000-M-SAF-64-bw
# STM-CSUB-1000-M-64-bw-200mbps
# STM-CSUB-1000-L-SAF-64-bw
# STM-CSUB-1000-L-64-bw-10mbps
# STM-CSUB-1000-H-SAF-64-bw
# STM-CSUB-1000-H-64-bw-1gbps
# STM-CSP-500-M1-64-bw-300mbps
# STM-CSP-500-L-64-bw-10mbps
# STM-CSP-500-L2-64-bw-100mbps
# SAFPX-CSUB
#
SKU='STM-DEV'
#
# There may be many versions available; how many freshest ones to include?
#
Versions='4'
#
OPTIND=1
force=0
prof=""

function show_help {
	printf "This script queries AWS for AMI IDs of Brocade Traffic Manager in all regions, and prints the respective\n"
	printf "\"Parameters\" and \"Mappings\" sections for CloudFormation template.\n\n"
	printf "When run, script checks for existence of per-region cached result files and re-uses contents, unless\n"
	printf "the script was executed with the \"-f\" parameter, in which case AWS is re-queried (takes long time).\n\n"
	printf "You can specify which AWS CLI profile to use with the \"-p <profile>\" parameter.\n\n"
	printf "Usage: $0 [-f] [-p <profile>]\n\n"
}

while getopts "h?fp:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    f)  force=1
        ;;
    p)  prof="--profile ${OPTARG}"
        ;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

declare -a regions
declare -a versions

regions=( $(aws $prof --region ap-southeast-2 ec2 describe-regions | awk -F "\"" ' /RegionName/ { print $4 }') )

pos=$(( ${#regions[*]} - 1 ))
for i in $(seq 0 $pos); do
	reg=${regions[$i]}
	printf "Querying region: %s\n" $reg
	fn="vADC-amis_"$reg"_txt"
	if [[ -a "$fn" && "$force" == "1" ]]; then
		echo "Force parameter was specified; deleting and re-creating \"$fn\" from AWS."
		rm -f "$fn"
	fi
	if [[ -a "$fn" ]]; then
		echo "Cached contents found for this region; re-run this script as \"$0 -f\" to force update."
	else
		aws $prof --region $reg ec2 describe-images --owners aws-marketplace --filters Name=name,Values="$vADCAMI" | awk -F "\"" ' /"Name"/ { printf "%s:", $4 }; /"ImageId"/ { printf "%s\n", $4 }' | grep "$SKU" | sed -e "s/ger-/ger:/g" -e "s/-x86/:x86/g" | awk -F ":" '{ printf "%s:%s\n", $2, $4 }' > "$fn"
		echo "Got $(wc -l $fn | awk '{print $1}') AMIs"
	fi
done

versions=( $(cat vADC-amis_* | awk -F: '{print $1}' | sort -n | uniq | tail -"$Versions") )
pos1=$(( ${#versions[*]} - 1 ))

printf "\n\nCut and paste the output below into your CloudFormation template:\n"
printf "=================================================================\n\n"

printf "  \"Parameters\" : {\n"
printf "    \"vADCVers\" : {\n"
printf "      \"Description\" : \"Please select vADC version:\",\n"
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
printf "      \"ConstraintDescription\" : \"Must be a valid vADC version\"\n"
printf "    }\n"
printf "  }\n\n"

printf "  \"Mappings\" : {\n"
printf "    \"vADCAMI\" : {\n"
for i in $(seq 0 $pos); do
	reg=${regions[$i]}
	fn="vADC-amis_"$reg"_txt"
	if [[ -s "$fn" ]]; then
		printf "      \"%s\" : {" $reg
		for j in $(seq 0 $pos1); do
			ver=${versions[$j]}
			ami=$(egrep "^$ver:" "$fn" | cut -f2 -d:)
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
