# vADC Auto-clustering example

This template uses AWS autoscaling group to deploy and manage a cluster of vADC instances.

To manage cluster membership, two shell scripts are used:

- `autocluster.sh` is ran once when a vADC is started by ASG. It checks for an existing cluster looking for specific tags. If it finds an existing cluster, it joins. If it doesn't, elections are run and if won the new instance forms a new cluster. The script is then terminated and vADC enters regular operation.
- `housekeeper.sh` is ran from cron on each running vADC instance in the cluster. It performs the following activities:
    - Checks if cluster members are the same as the running vADC instances. If it finds any cluster members that don't have a corresponding running vADC instance, it removes them from the cluster.
    - Ensures that each running vADC instance has as many secondary private IP addresses as there are Traffic IPs in the cluster (as per the number passed from the CloudFormation template). This is to ensure each vADC can accommodate all Traffic IPs in case of failure of others.
    - Ensures that public IPs of all running vADCs are listed in a Route53 zone, if {{vADCFQDN}} parameter is specified. This is for vADC cluster management access.

Note: as it stands, CloudFormation will fail to delete this stack because Route53 HostedZone is modified by means other than CloudFormation itself. I've created a Lambda wrapper function that can be found [here](https://github.com/dkalintsev/Bits-and-bobs/tree/master/Route53-HostedZone-Lambda-Wrapper). I will intergarte it soon.

