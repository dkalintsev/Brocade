# Autoclustering Brocade vADC + example web server + config by Puppet

This template builds on a couple of earlier templates: [vADC Cluster configured by Puppet](https://github.com/dkalintsev/Brocade/tree/master/vADC/CloudFormation/Templates/Variants-and-experimental/Configured-by-Puppet) and [Autoclustering vADCs](https://github.com/dkalintsev/Brocade/tree/master/vADC/CloudFormation/Templates/Variants-and-experimental/Autoclustering).

As before, this is a proof-of-concept quality code, which is meant to provide a starting point for you to develop a production-ready solution.

## What's in the box

* `vADC-ASG-Puppet.template` - main template. As usual, download and deploy from your computer via CLI or CloudFormation UI, or use "Launch Stack" button below.
* `cluster-config-template.pp` - example parametrised Puppet manifest for the vADC cluster config
* `UpdateClusterConfig.sh` - script that generates vADC cluster config populated with the IPs of currently running vADC instances and backend pool servers. It is run periodically to keep cluster config up to date if/when necessary.
* `autocluster.sh` is ran once when a vADC is started by ASG. It checks for an existing cluster looking for specific tags. If it finds an existing cluster, it joins. If it doesn't, elections are run and if won the new instance forms a new cluster. The script is then terminated and vADC enters regular operation.
* `housekeeper.sh` is ran from cron on each running vADC instance in the cluster. It performs the following activities:
    - Checks if cluster members are the same as the running vADC instances. If it finds any cluster members that don't have a corresponding running vADC instance, it removes them from the cluster.
    - Ensures that each running vADC instance has as many secondary private IP addresses as there are running vADC instances. This is to ensure each vADC can accommodate all Traffic IPs in case of failure of others.

## What does the template do

At the high level, it builds this:

![Diagram](https://raw.githubusercontent.com/dkalintsev/Brocade/master/vADC/CloudFormation/Templates/Variants-and-experimental/ASG-Puppet/images/vADC%20with%20Puppet%20and%20Web%20Servers.png "High level diagram")

The first part deploys an Auto Scaling Group that spawns 2 vADC instances, set up to automatically form a cluster.

The second part of the template is concerned with two additonal bits:

- 2 x Web servers, representing our "application", started through the second Auto Scaling Group; and
- A third Auto Scaling Group that spawns one EC2 instance with Puppet that (a) pushes the initial config to the vADC cluster, and (b) watches for any changes in running vADC EC2 instances and Web servers' IPs, for example if an AutoScale event happens, and updates vADC cluster config accordingly.

Since the template creates an Internet-facing "web app", it also creates two EIPs that will be used for a vADC Traffic Group. vADCs sort between themselves which one of them owns which of these EIPs.

Template also creates a Route53 DNS zone, by default for domain `corp.local` and creates A records for `www.corp.local` and ALIAS for `corp.local` pointing to the two EIPs. If you would like to access your demo app at http(s)://www.corp.local, you'll need to delegate the NS for corp.local to the AWS Route53 servers associated with your newly created zone. To find out what these are, you'll need to open AWS Console UI, go to Route53, and look for the NS records for your hosted zone (`corp.local` if you used the defaults).

Alternatively you can simply create the A records on your DNS server directly. `Outputs` section in the stack prints out the domain name and public IP addresses that vADCs will be listening on, for example:

```
URL: corp.local, IP1: 52.65.69.185, IP2: 52.62.54.195
```

Public/Private SSL certs included with the template are self-signed for *.corp.local. - please note that they need to be in comma-delimited format. To convert your cert files into comma-delimited format, you can use something similar to the following command:

`awk 1 ORS=',' < myfile.crt > myfile-comma.crt`

You will also notice the template creates a NAT gateway - it's there purely to provide our Web servers sitting in the private subnets ability to reach to the Internet and install Apache.

## How is this supposed to work

While clearly being a demo, the template was designed to provide building blocks for roughly the following real life workflow:

1. You have an application that requires vADC. You could be using a [simple template](https://github.com/dkalintsev/Brocade/tree/master/vADC/CloudFormation/Templates) customised for your needs to deploy an unconfigured vADC cluster.
2. You deploy the rest of your application.
3. Using vADC UI and CLI, as necessary, you configure vADC cluster as your appication requires.
4. Once the above is in place, you run [`genNodeConfig`](https://forge.puppet.com/tuxinvader/brocadevtm#tools-gennodeconfig) to create a Puppet manifest from your running configured cluster.
5. You then edit the resulting Puppet manifest, replacing the deployment-specific bits inside the manifest, such as IP addresses, DNS names, logins/passwords, SSL certs and so on with mustache-formatted variables, e.g., {{AdminPass}}. This will look something like the [cluster-config-template.pp](https://github.com/dkalintsev/Brocade/blob/master/vADC/CloudFormation/Templates/Variants-and-experimental/ASG-Puppet/cluster-config-template.pp) manifest file in this repo. Once done, you upload the resuting parametrised manifest somewhere where `Puppet` resource from your application stack can get it from later - Git, S3, whatever.
6. Then you grab the `PuppetASG` and `vADCGroup` resources from this template with their dependencies, add them to yours, adjusting the `/root/cluster-config-template.pp` section of the `PuppetLaunchConfig` resource such that it points to the URL of your parametrised manifest, and has the appropriate variables in the `context` section.

If all goes well, you should be all set. :)

For a demo / test purposes, you can use this template directly. Make note of the Route53 bit decribed above.

## Bits and bobs

- The original Puppet manifest (as per step 4 above) was generated using the following command, after configuring vADC cluster through the UI:

`/etc/puppet/modules/brocadevtm/bin/genNodeConfig -h x.x.x.x -U admin -P Password123 -v 3.9 -sn -o cluster-config-template-raw.pp`

When generating your own manifest, please make sure to give `-v` parameter the REST API [version that matches your vADC cluster software](https://forge.puppet.com/tuxinvader/brocadevtm#rest-version-mapping).

- Template doesn't add a license key or link your cluster to a Services Director.

- Tested with vADC version 11.0, 11.1, and 17.1. Please let me know if you hit problems.

## How to use

You can deploy this template directly through AWS console or CLI, by downloading it to your computer first. All inputs are fairly clearly labelled, and should present no trouble. Once the deployment is complete, connect to your new vADC cluster on the URL displayed in the `vADCManagementURLs` of the template's `Output`, and login as admin with the password that you've supplied, or "Password123" if you accepted the default. The HTTP/HTTPS URLs for your example web app are also there under `WebAppURLs`.

You can also launch this template into the `us-east-1` region by clicking the "Launch Stack" button below:

<a href="https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=Brocade-vADC-webapp&templateURL=https://s3-ap-southeast-2.amazonaws.com/7pjmj9xxfjlcnq/vADC/CloudFormation/Templates/Variants-and-experimental/ASG-Puppet/vADC-ASG-Puppet.template"><img src="https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png"></a>


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

**Q**: I selected a vADC version "xxx", and deployment has failed. I'm subscribed to the product. I also see something about product being no longer available from Marketplace in the CloudFormation Events log.  
**A**: I could not find any way to tell which images that Marketplace query returns are actually "active" from the ones that are not. Information returned by the "describe-images" CLI command for the AMIs that are active/deployable and the ones that "no longer available" provides no clues - they both look identical. :( The only reliable way to tell which version really is available it to visit product's page in Marketplace, and click "(Other available versions)". :( 

**Q**: Why do you present drop-down of AZs? Can't you just use Fn::GetAZs?  
**A**: AWS at present has no means of guaranteeing that all AZs returned by Fn::GetAZs will allow creation of subnets in them. See [this stackoverflow thread](http://stackoverflow.com/questions/21390444/is-there-a-way-for-cloudformation-to-query-available-zones-for-subnet-creation) for more detail. AWS person responsible for VPC docs told me that this limitation is still current, and they are not aware of a solution. If you look at the [AWS's own CloudFormation template for creation of VPCs](http://docs.aws.amazon.com/quickstart/latest/vpc/welcome.html), they're using the same "trick".

**Q**: Why do you display vADC version numbers without dots?  
**A**: I'm using them as a key to look up AMI IDs in a map. CloudFormation only accepts alphanumerical characters in keys, so dots are no-go. :(

**Q**: What's the story with licensing?  
**A**: The AMI IDs in this template correspond to the Developer Edition of vADC. It has all features enabled, but is limited to 2 Mbit/s of throughput. Developer edition can be converted to a fully functional instance by giving it a valid license, either directly or through a Service Director. Alternatively, you can modify the template with the AMIs of one of the licensed versions of vADC. To help with this, you can use the [`vADC-amis.sh`](https://github.com/dkalintsev/Brocade/blob/master/CloudFormation/Tools/vADC-amis.sh) script. Modify the value of the `SKU` varible near the start of the script to the one you want, and run it from a machine that has AWS CLI installed with permissions to list AWS Marketplace items.

**Q**: What's the support status of this? Is this official?  
**A**: This template is considered "experimental/unofficial", but I encourage you to open GitHub issues and/or submit pull requests as you see fit, and I'll deal with them when I can. This will also help us determine whether there's enough interest in a template, so that we can make it official/supported.

**Q**: Can I modify/reuse this?  
**A**: This repo is Creative Commons, so you can use what you find here in whichever way you see fit, with or without credit.