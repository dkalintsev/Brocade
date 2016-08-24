# Brocade vRouter sample deployment template

This is an example AWS CloudFormation template for deplopying a pair of Brocade vRouter virtual appliances into a VPC spanning two Availability Zones.

The purpose of this template is to provide a starting point for deployment automation of applications that incorporate Brocade vRouter.

One obvious example is the vRouter HA solution published [on Brocade Community Forum](https://community.brocade.com/t5/SDN-NFV/vRouter-HA-in-AWS-across-Availability-Zones/ta-p/86905). This template builds everything up to the point in the solution that starts with "Create a GRE tunnel...", where you would have a pair of vRouters running and accessible via SSH, and can start with configuration tasks.

There are many opportunities for improvement, and I'll be testing and incorporating them over time.

On the near-term to-do list are:
- Port to use Autoscale Groups
- Functionality for vRouters to pull their configuration from a repository, tentatively GitHub (this has dependency on the upcoming cloud-init support)
- Add an ability to choose any number of AZs between one and four, which will deploy a vRouter into each selected AZ.

This template includes AMIs for vRouter versions available at the time of writing. Please see the [tools](https://github.com/dkalintsev/Brocade/tree/master/CloudFormation/Tools) directory for the vR-amis.sh script that you can use to generate fresh set of AMIs when things change, like wnen new vRouter versions come out, or when AWS adds more regions.

## What does this template currently do

As it stands now, it does the following:

1. Collects the deployment parameters:
  1. The IP subnets it needs to build a new VPC with 2 x AZs and 2 x subnets in each - one public and one private (4 x subnets in total);
  2. vRouter version, appliance size, and SSH key name;
  3. The subnet or an IP that will be allowed SSH access to the vRouter appliances;
2. Creates the following resources:
  1. A VPC
  2. 4 x subnets (2 in each AZ selected above)
  3. An Internet Gateway, attached to the VPC
  4. A routing table for the 2 x public subnets, with a default route pointing at the IGW
  5. A Security Group for the vRouters, with the ports needed for SSH acces, plus 80 and 443 in case vRouters are used as NAT gateways;
  6. 2 x Elastic IPs for vRouters
  7. 4 x Elastic Network Interfaces with SourceDestCheck disabled, with attached Security Groups. Two of these with EIPs;
  8. An IAM Role that grants vRouter appliances the rights to manipulate VPC routing tables, as required by the HA solution linked above;
  9. Two vRouter instances, where each vRouter has one interface in a public subnet and another in a private subnet in its AZ;
  10. Two CloudWatch Recovery Alarms, one per vRouter instance, that will try to recover them if underlying EC2 status checks fail for 15 minutes; and
  11. Last but not least, two more route tables, each with a default route pointing to a vRouter interface connected to the private subnet. These tables are then associated with the corresponding private subnets.
3. Output some values, such as allocated public IPs associated with the vRouters that you can SSH into to follow with further configuration tasks, as well as vRouters' IP addresses in private subnets, that you'll need when configuring them.

Please note that the HA solution linked above assumes that both private subnets have their default route pointing to the same vRouter instance, which is different from what this template does. It is very easy to change by editing NetworkInterfaceId on the PrivateSubnetRoute1 or PrivateSubnetRoute2 resources to point to the vRouter instance you choose to be your "Active" one.

The template as published will set up routing table in each AZ's private subnet to point to the vRouter in the same AZ, to avoid incurring cross-AZ data transfer fees.

The template has been tested and seems to work well, but you should not treat it as production-ready without doing your own testing / verification.

## How to use

You can deploy this template directly through AWS console or CLI. All inputs are fairly clearly labelled, and should present no trouble. Once the deployment is complete, connect to your new vRouter instances, and configure them accordingly.

By default, only one interface, the one connected to the public subnet, will be configured. It will have its IP address assigned by DHCP. The second interface, connected to the private subnet, will have no IP address, and you will need to set it manually to the private IP assigned by AWS. You can find that private IP address for both vRouter instances in the stack Outputs under "vRouter 1 Private IP 2" / "vRouter 2 Private IP 2", respectively.

Click the button to deploy the stack now into us-east-1:
[![Deploy Stack](http://cdn.amazonblogs.com/application-management_awsblog/images/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=vRouter-HA&templateURL=https://github.com/dkalintsev/Brocade/blob/master/vRouter/CloudFormation/Templates/vRouter-Deploy.template)
