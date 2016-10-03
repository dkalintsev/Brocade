# Brocade vADC + example web server + config by Puppet

This template builds on the [parent one](https://github.com/dkalintsev/Brocade/tree/master/vADC/CloudFormation/Templates) (while changing a few things - more on that below). Most notably, it adds an EC2 instance that uses a [vADC Puppet Module](https://forge.puppet.com/tuxinvader/brocadevtm) to push some very simple configuration to the vADC cluster, making it serve content over HTTP and HTTPS from two Web Server EC2 instances.

As before, this is a proof-of-concept quality code, which is meant to provide a starting point for you to develop a production-ready solution.

## What's in the box

* `vADC-Deploy-Puppet-EIP.template` - main template. As usual, download and deploy from your computer via CLI or CloudFormation UI, or use "Launch Stack" button below.
* `example.pp` - Example parametrised Puppet manifest for the vADC cluster config
* `QueryWebServers.sh` - script to update the cluster-specific manifest file with the IPs of the backend pool servers. It is run periodically to adjust backend pool config if/when necessary. 

## What does the template do

The first part that builds the cluster of 2 x vADCs is very similar to the [parent template](https://github.com/dkalintsev/Brocade/tree/master/vADC/CloudFormation/Templates), with a few small adjustments:

- vADCs no longer use Elastic IPs, because otherwise this template would have needed more than AWS gives you by default (5 per region) due to additional requirements. Instead, they just get allocated public IPs dynamically. Also, template no longer uses ENIs for vADCs.
- vADCs get 2x secondary private IPs each, to accommodate the 2x EIPs for our Traffic Group.
- We enable REST API on the vADCs, so that our Puppet server can do its thing.

The second part of the template is all concerned with two additonal bits:

- 2 x Web servers, representing our "application", started through an AutoScale Group; and
- An EC2 instance with Puppet that (a) pushes the initial config to the vADC cluster, and (b) watches for any changes in Web servers' IPs, for example if an AutoScale event happens, and updates vADC cluster config accordingly.

Since the template creates an Internet-facing "web app", it also creates two EIPs that will be used for a vADC Traffic Group. vADCs sort between themselves which one of them owns which of these EIPs.

It also creates a Route53 DNS zone, by default for domain `corp.local` and creates A records for `www.corp.local` and ALIAS for `corp.local` pointing to the two EIPs. If you would like to access your demo app at http(s)://www.corp.local, you'll need to delegate the NS for corp.local to the AWS Route53 servers associated with your newly created zone. To find out what these are, you'll need to open AWS Console UI, go to Route53, and look for the NS records for your hosted zone (`corp.local` if you used the defaults).

Public/Private SSL certs included with the template are self-signed for *.corp.local. - please note that they need to be in comma-delimited format. To convert your cert files into comma-delimited format, you can use something similar to the following command:

`awk 1 ORS=',' < myfile.crt > myfile-comma.crt`

You will also notice the template creates 2 x NAT gateways - these are there purely to provide our Web servers sitting in the private subnets ability to reach to the Internet and install Apache.

## How is this supposed to work

While clearly being a demo, the template was designed to provide building blocks for roughly the following real life workflow:

1. You have an application that requires vADC. You could be using the [parent template](https://github.com/dkalintsev/Brocade/tree/master/vADC/CloudFormation/Templates) customised for your needs to deploy an unconfigured vADC cluster.
2. You deploy the rest of your application.
3. Using vADC UI and CLI, as necessary, you configure vADC cluster as your appication requires.
4. Once the above is in place, you run [`genNodeConfig`](https://forge.puppet.com/tuxinvader/brocadevtm#tools-gennodeconfig) to create a Puppet manifest from your running configured cluster.
5. You then edit the resulting Puppet manifest, replacing the deployment-specific bits inside the manifest, such as IP addresses, DNS names, logins/passwords, SSL certs and so on with mustache-formatted variables, e.g., {{AdminPass}}. See what this looks like in the [example.pp](https://github.com/dkalintsev/Brocade/blob/master/vADC/CloudFormation/Templates/Variants%20and%20experimental/Configured%20by%20Puppet/example.pp) manifest file in this repo. Once done, you upload the resuting parametrised manifest somewhere where `Puppet` resource from your application stack can get it from later - Git, S3, whatever.
6. Then you grab the `Puppet` resource from this template with its dependencies, add it to yours, adjusting the `/root/example.pp` section such that it points to the URL of your parametrised manifest, and has the appropriate variables in the `context` section.

If all went well, you should be all set. :)

For a demo / test purposes, you can use this template directly. Make note of the Route53 bit decribed above.

## Bits and bobs

- The original Puppet manifest (as per step 4 above) was generated using the following command, after configuring vADC cluster through the UI:

`/etc/puppet/modules/brocadevtm/bin/genNodeConfig -h 10.8.1.123 -U admin -P Password123 -v 3.9 -sn -o example-raw.pp`

- Template doesn't add a license key or link your cluster to a Services Director.

- I've only really tested with vADC version 11.0. Please let me know if you hit problems.

## How to use

You can deploy this template directly through AWS console or CLI, by downloading it to your computer first. All inputs are fairly clearly labelled, and should hopefully present no trouble. Once the deployment is complete, connect to your new vADC cluster on the URL displayed in the Output, and login as admin with the password that you've supplied, or "Password123" if you accepted the default. Your example web app should be accessible through HTTP or HTTPS on the domain you've specified (if you've delegated the DNS zone to Route53), or on either of the WebAppIPs in the Outputs section after deployment.

You can also launch this template into us-east-1 region by clicking the "Launch Stack" button below:

<a href=
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=Brocade-vADC&templateURL=https://s3-ap-southeast-2.amazonaws.com/7pjmj9xxfjlcnq/vADC/CloudFormation/Templates/Variants%20and%20experimental/Configured%20by%20Puppet/vADC-Deploy-Puppet-EIP.template>
<img src=https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png></a>


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