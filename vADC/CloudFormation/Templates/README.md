# Brocade vADC (Virtual Traffic Manager + WAF) sample deployment template

This is an example AWS CloudFormation template for deplopying a cluster of 2 x Brocade vADC appliances into a VPC spanning two Availability Zones.

The purpose of this template is to provide a starting point for deployment automation of applications that incorporate Brocade vADC. There are many opportunities for improvement, and I'll be testing and incorporating them over time.

On the near-term to-do list are:
- Add an ability to choose at deploy time whether vADC instances should be deployed with one or two interfaces (one for public, one for private subnet)
- Port to use Autoscale Groups
- Functionality for vADC cluster to pull its configuration from a repository, tentatively GitHub

Note: there are many vADC SKUs available on AWS Marketplace. This template uses Developer Edition, which is fully functional, but limited to a small throughput. 

This was done for two reasons:
- To save on the licensing costs for dev deployment scenarios; and
- Developer Edition can be later turned to a fully-functional one by applying a BYO license

If this is not what you want, you can replace the AMI IDs with the ones that suit your needs. Please see the [tools](https://github.com/dkalintsev/Brocade/tree/master/CloudFormation/Tools) directory for the vADC-amis.sh script where you can adjust the malue of the "SKU" variable at the beginning of the script to match your desired SKU. Run the script with the "-f" flag after changing the SKU, forcing it re-fetch the AMIs. It will produce the new vADCAMI map that you'll need to paste into the template, replacing the one already in there.  

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

At high level:

![Diagram](https://raw.githubusercontent.com/dkalintsev/Brocade/master/vADC/CloudFormation/Templates/images/vADC%20Cluster.png "High level diagram")

The template has been tested and seems to work well, but you should not treat it as production-ready without doing your own testing / verification.

## How to use

You can deploy this template directly through AWS console or CLI, by downloading it to your computer first. All inputs are fairly clearly labelled, and should hopefully present no trouble. Once the deployment is complete, connect to your new vADC cluster on the URL displayed in the Output, and login as admin with the password that you've supplied, or "Password123" if you accepted the default. Your cluster should be ready to take your application-specific configuration.

You can also launch this template into us-east-1 region by clicking the "Launch Stack" button below:

<a href=
"https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=Brocade-vADC&templateURL=https://s3-ap-southeast-2.amazonaws.com/7pjmj9xxfjlcnq/vADC/CloudFormation/Templates/vADC-Deploy-cfn-init.template">
<img src="https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png"></a>

**Note**: You will need to activate either hourly or annual subscription to Brocade vADC software through the AWS Marketplace before you'll be able to deploy this template successfully. To do this:

1. Visit [AWS Marketplace](https://aws.amazon.com/marketplace/)
2. Type "brocade virtual traffic manager" into the "Search AWS Marketplace" box and click "Go"
3. Click the "Brocade Virtual Traffic Manager Developer Edition" in the results (or select an appropriate different one if you've selected a different SKU)
4. Select **Hourly** or **Annual** in the *"Pricing Details"* box
5. Click "Continue" button
6. On the next screen, first click "Manual Launch" tab away from pre-selected "1-Click Launch", then click yellow "Accept Software Terms" button in the "Price for your selections" box.

## Q&A

**Q**: My deployment sits forever at *"CREATE\_IN\_PROGRESS"* of vADC instances, then fails and rolls back. In the "Status reason" of CloudFormation "Events" log I see a message similar to *"In order to use this AWS Marketplace product you need to accept terms and subscribe. To do so please visit http://aws.amazon.com/marketplace/pp?sku=30zvsq8o1jmbp6jvzis0wfgdt"* against the vADC1 AWS::EC2::Instance.  
**A**: You haven't subscribed to Brocade vADC software through the AWS Marketplace yet. Please visit the link CloudFormation has shown (which may be different from the one above), which will take you to the step #4 in the subscription instructions above the Q&A. Once subscribed, select "Delete Stack", and try deploying again. Please note that there are many SKUs available; so make sure you subscribe to the one that your template is trying to deploy. The easiest way to get to the right one is to visit the URL that CloudFormation tells you in the error message. :)

**Q**: I don't need the vADC anymore. How can I cancel my subscription?  
**A**: Visit [Your Software Subscriptions](https://aws.amazon.com/marketplace/library/) in AWS Marketplace, and click "Cancel Subscription" against the "Brocade Virtual Traffic Manager Developer Edition", or the appropriate other edition you may have chosen.

**Q**: I selected a vADC version "100", and deployment has failed. I'm subscribed to the product. I also see something about product being no longer available from Marketplace in the CloudFormation Events log.
**A**: I could not find any way to tell which images that Marketplace query returns are actually "active" from the ones that are not. Information returned by the "describe-images" CLI command for the AMIs that are active/deployable and the ones that "no longer available" provides no clues - they both look identical. :( The only reliable way to tell which version really is available it to visit product's page in Marketplace, and click "(Other available versions)". :( 

**Q**: Why do you present drop-down of AZs? Can't you just use Fn::GetAZs?  
**A**: AWS at present has no means of guaranteeing that all AZs returned by Fn::GetAZs will allow creation of subnets in them. See [this stackoverflow thread](http://stackoverflow.com/questions/21390444/is-there-a-way-for-cloudformation-to-query-available-zones-for-subnet-creation) for more detail. AWS person responsible for VPC docs told me that this limitation is still current, and they are not aware of a solution. If you look at the [AWS's own CloudFormation template for creation of VPCs](http://docs.aws.amazon.com/quickstart/latest/vpc/welcome.html), they're using the same "trick".

**Q**: Why do you display vADC version numbers without dots?  
**A**: I'm using them as a key to look up AMI IDs in a map. CloudFormation only accepts alphanumerical characters in keys, so dots are no-go. :(