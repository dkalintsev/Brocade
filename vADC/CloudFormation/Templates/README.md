# Brocade vADC (Traffic Manager + WAF) sample deployment template

This is an example AWS CloudFormation template for deplopying a cluster of Brocade vADC virtual appliances into a VPC spanning two Availability Zones.

The purpose of this template is to provide a starting point for deployment automation of applications that incorporate Brocade vADC. There are many opportunities for improvement, and I'll be testing and incorporating them over time.

On the near-term to-do list are:
- Port to use Autoscale Groups
- Functionality for vADC cluster to pull its configuration from a repository, tentatively GitHub
- Add an ability to choose at deploy time whether vADC instances should be deployed with one or two interfaces (one for public, one for private subnet)

Note: there are many vADC SKUs available on AWS Marketplace. This template uses Developer Edition, which is fully functional, but limited to a small throughput. 

This was done for two reasons:
- To save on the licensing costs for dev deployment scenarios; and
- Developer Edition can be later turned to a fully-functional one by applying a BYO license

If this is not what you want, you can replace the AMI IDs with the ones that suit your needs. Please see the [tools](https://github.com/dkalintsev/Brocade/tree/master/CloudFormation/Tools) directory for the vADC-amis.sh script that should be easy to modify to help with this.

## What does this template currently do

As it stands now, it does the following:

1. Collects the deployment parameters:
  1. The IP subnets it needs to build a new VPC with 2 x AZs and 2 x subnets in each - one public and one private (4 x subnets in total);
  2. vADC version, appliance size, SSH key name, and admin password;
  3. The subnet or an IP that will be allowed SSH access to the vADC appliances;
2. Creates the following resources:
  1. A VPC
  2. 4 x subnets (2 in each AZ selected above)
  3. An Internet Gateway, attached to the VPC
  4. A routing table for the 2 x public subnets, with a default route pointing at the IGW
  5. A Security Group for the vADCs, with the ports needed for vADCs to cluster, be managed, and to serve HTTP and HTTPS traffic
  6. 2 x Elastic IPs for vADCs
  7. 2 x Elastic Network Interfaces with SourceDestCheck disabled, and attaches Security Groups and EIPs to them
  8. An IAM Role, that grants vADC appliances rights to manage themselves (which could be further tightened at a later stage...)
  9. First vADC instance that creates a new vTM cluster, and then signals that the second instance can be deployed, thorugh a WaitHandler
  10. Second vADC instance, that is told to join the first one's cluster
  11. Two CloudWatch Recovery Alarms, one per vADC instance, that will try to recover them if underlying EC2 status checks fail for 15 minutes
3. Output some values, such as allocated public IPs associated with the vADCs, and the Admin URL that you can click to access the vADC cluster management UI.

The template has been tested and seems to work well, but you should not treat it as production-ready without doing your own testing / verification.

## How to use

You can deploy this template directly through AWS console or CLI. All inputs are fairly clearly labelled, and should hopefully present no trouble. Once the deployment is complete, connect to your new vADC cluster on the URL in the Output, and login as admin with the password that you've supplied, or "Password123" if you accepted the default. Your cluster should be ready to take your application-specific configuration.

You can also launch this template into us-east-1 region by clicking the "Launch Stack" button below:

<a href=
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=Brocade-vADC&templateURL=https://s3-ap-southeast-2.amazonaws.com/7pjmj9xxfjlcnq/vADC/CloudFormation/Templates/vADC-Deploy-cfn-init.template>
<img src=https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png></a>
