# Variants and Experemental versions

This directory holds variations and experemental versions of the vADC template master from the parent directory.

## `vADC-dual-NIC.template`

This template deploys the same stack as the one in the parent directory, but with a little twist: it creates two ENIs (NICs) for each vADC instance, and connects the second ENI to the private subnet in the respective Avaiability Zone.

In some deployment scenarios, it may be desirable to follow the traditional dual-homed vADC connectivity models, where one NIC is connected to public/DMZ "network", while another is connected to private one.

To make this configuration work, we need to deal with a couple of additional things:

- Make sure our instance doesn't have two default gateways, which will be the case if both NICs get their address from DHCP; and
- Configure instance routing table so that it knows which NIC to use when trying to reach certain destinations. In our case, server pool members will be either in private subnets, or may even be outside of AWS, reachable via a VGW accessible to private subnets.

This template will prompt for the `Server Pool CIDR Block`, and add a route for that subnet on both vADC instances, pointing out of vADCs' NICs connected to private subnets.

The subnet is set by default to match the 2 x private subnets' CIDRs created by this template (10.8.4.0/24 + 10.8.4.0/24). If your stack has server pool members that sit outside AWS or in a different VPC, please adjust the `Server Pool CIDR Block` accordingly.

To deal with the "double default gateway" issue, template runs a couple commands during initial configuration, where it resets the configuration for the second NIC, creates a static config for it, and then brings that second NIC up. All of that is done inside `default` configSet of `AWS::CloudFormation::Init` Metadata for the vADC instances.

