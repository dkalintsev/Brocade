# Brocade vRouter sample deployment template

This is an example AWS CloudFormation template for deplopying Brocade vRouter virtual appliance(s) into a new VPC spanning two or three Availability Zones.

The purpose of this template is to provide a starting point for deployment automation of applications that incorporate Brocade vRouter.

One obvious example is the vRouter HA solution published on the [Brocade Community Forum](https://community.brocade.com/t5/SDN-NFV/vRouter-HA-in-AWS-across-Availability-Zones/ta-p/86905). To match this solution, you can deploy this template with 2 x Availability Zones and 2 x vRouters, and it will build everything up to the point that starts with "Create a GRE tunnel...". From there you will have a pair of vRouters running and accessible via SSH, and can start with the configuration tasks.

There are many opportunities for improvement, and I'll be testing and incorporating them over time.

On the near-ish term to-do list are:
- Port to use Autoscale Groups
- Functionality for vRouters to pull their configuration from a repository, tentatively GitHub (this has dependency on the upcoming cloud-init support)

This template includes AMIs for vRouter versions available at the time of writing. Please see the [tools](https://github.com/dkalintsev/Brocade/tree/master/CloudFormation/Tools) directory for the vR-amis.sh script that you can use to generate a fresh set of AMIs when things change, like when new vRouter versions come out, or AWS adds more regions.

## What does this template currently do

As it stands now, it does the following:

1. Collects the deployment parameters:
  1. AZ and vRouter configuration: which AZs to create private and public subnets in, how many vRouter appliances to deploy, vRouter software version to use, instance type, and SSH key;
  2. Network configuration: CIDR blocks for the VPC and subnets; and
  3. The subnet or an IP that will be allowed SSH access to the vRouter appliances.
2. Creates the following resources:
  1. A VPC
  2. Two subnets, one public and one private, for each of the selected AZs;
  3. An Internet Gateway, attached to the VPC;
  4. A routing table for the public subnets, with the default route pointing at the IGW
  5. A Security Group for vRouters, with the ports needed for SSH acces, plus 80 and 443 in case vRouters will be used as NAT gateways;
  6. Elastic IPs for vRouters
  7. Elastic Network Interfaces with SourceDestCheck disabled, configured with Security Groups. Two interfaces per vRouter - to connect to public and private subnets, respectively. Public subnet ENIs will have EIPs attached.
  8. An IAM Role that grants vRouter appliances the rights to manipulate VPC routing tables, as required by the HA solution linked above;
  9. Your chosen number of vRouter instances - between one and three, each placed into a different AZ;
  10. CloudWatch Recovery Alarms, one per vRouter instance, that will try to recover them if underlying EC2 status checks fail for 15 minutes; and
  11. Last but not least - private subnet route tables, each with a default route pointing to a vRouter interface connected to that private subnet. These tables are then associated with the corresponding private subnets. *If you select a number of vRouters that is smaller than the number of AZs, template will point the default route in private subnet(s) without a vRouter to the vRouter instance in the first AZ you've selected.* **This will cause some cross-AZ traffic, which is not free.** 
3. Output some values, such as allocated public IPs associated with the vRouters that you can SSH into to follow with further configuration tasks, as well as vRouters' IP addresses in private subnets, that you'll need when configuring them.

Please note the HA solution linked above assumes that both private subnets have their default route pointing to the same vRouter instance, which is different from what this template does. If you'd like to follow the HA guide, you can either download the template and edit it before deploying, or adjust the routing table in your second private subnet after deployment. The change you'll need to make is to replace *"Fn::If": [...]* with *{ "Ref": "vRouter1Interface2" }* in the *"PrivateSubnetRoute2"* resource.

The template as published will set up routing table in each AZ's private subnet to point to the vRouter in the same AZ, to avoid incurring cross-AZ data transfer fees. Please see note above in 2.xi on what happens when you request more AZs than vRouters.

The template has been tested and seems to work well, but you should not treat it as production-ready without doing your own testing / verification.

## How to use

You can deploy this template directly through AWS console or CLI, by downloading it to your computer first. All inputs are fairly clearly labelled, and should present no trouble. Once the deployment is complete, connect to your new vRouter instance(s), and configure them accordingly.

By default, only one interface, the one connected to the public subnet, will be configured. It will have its IP address assigned by DHCP. The second interface, connected to the private subnet, will have no IP address, and you will need to set it manually to the private IP assigned by AWS. You can find that private IP address for your vRouter instances in the stack Outputs under *"vRouter N Private IP 2"*.

You can also launch this template into us-east-1 region by clicking the "Launch Stack" button below:

<a href=
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=Brocade-vRouter&templateURL=https://s3-ap-southeast-2.amazonaws.com/7pjmj9xxfjlcnq/vRouter/CloudFormation/Templates/vRouter-Deploy.template>
<img src=https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png></a>

**Note**: You will need to activate either hourly or annual subscription to vRouter 5600 software through the AWS Marketplace before you'll be able to deploy vRouter instances successfully. To do this:

1. Visit [AWS Marketplace](https://aws.amazon.com/marketplace/)
2. Type "5600" into the "Search AWS Marketplace" box and click "Go"
3. Click the "Brocade 5600 Virtual Router/Firewall/VPN" in the results
4. Select **Hourly** or **Annual** in the *"Pricing Details"* box
5. Click "Continue" button
6. On the next screen, first click "Manual Launch" tab away from pre-selected "1-Click Launch", then click yellow "Accept Software Terms" button in the "Price for your selections" box.

## Q&A

**Q**: My deployment sits forever at *"CREATE\_IN\_PROGRESS"* of vRouter instances, then fails and rolls back. In the "Status reason" of CloudFormation "Events" log I see the message similar to *"In order to use this AWS Marketplace product you need to accept terms and subscribe. To do so please visit http://aws.amazon.com/marketplace/pp?sku=7of3sgnx2ow2c29618xcrp01v"* against vRouter1 AWS::EC2::Instance.  
**A**: You haven't subscribed to Brocade vRouter software through the AWS Marketplace yet. Please visit the link CloudFormation has shown (which may be different from the one above), which will take you to the step #4 in the subscription instructions above the Q&A. Once subscribed, select "Delete Stack", and try deploying again.

**Q**: I don't need the vRouter anymore. How can I cancel my subscription?  
**A**: Visit [Your Software Subscriptions](https://aws.amazon.com/marketplace/library/) in AWS Marketplace, and click "Cancel Subscription" against the "Brocade 5600 Virtual Router/Firewall/VPN".

**Q**: Why do you present drop-down of AZs? Can't you just use Fn::GetAZs?  
**A**: AWS at present has no means of guaranteeing that all AZs returned by Fn::GetAZs will allow creation of subnets in them. See [this stackoverflow thread](http://stackoverflow.com/questions/21390444/is-there-a-way-for-cloudformation-to-query-available-zones-for-subnet-creation) for more detail. AWS person responsible for VPC docs told me that this limitation is still current, and they are not aware of a solution. If you look at the [AWS's own CloudFormation template for creation of VPCs](http://docs.aws.amazon.com/quickstart/latest/vpc/welcome.html), they're using the same "trick".

**Q**: Why are you asking for how many AZs I've selected? Can't you just count the input?  
**A**: Unfortunately CloudFormation doesn't have functions that can count the number of elements in a list. :( See the AWS's VPC template linked above - same story.

**Q**: Can you configure vRouter directly from this template?  
**A**: Not at the moment. This needs support for cloud-init, which will be coming to vRouter later in the year.

**Q**: Why do you display vRouter version numbers without dots?  
**A**: I'm using them as a key to look up AMI IDs in a map. CloudFormation only accepts alphanumerical characters in keys, so dots are no-go. :(

**Q**: Why aren't you using Autoscale Groups to launch vRouter instances?  
**A**: vRouters are deployed with multiple interfaces connected to different subnets, and ASGs don't allow you to specify this. I think I have a solution for this, which I'll try once the cloud-init support is in place.