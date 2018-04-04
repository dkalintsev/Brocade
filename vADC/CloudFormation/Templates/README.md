# What happened here?

## NOTE: THIS REPO HOLDS A BUNCH OF TEMPLATE THAT ARE NO LONGER SUPPORTED
## PLEASE USE [THIS] (https://github.com/dkalintsev/vADC-CloudFormation/) INSTEAD.

I've moved things around:

- Templates that probably not worth keeping updated are now in `Old`.
- `Configured-by-Puppet` has been promoted to the "safe choice", as it's the most mature one. Note that if you'd like to use vADC v17.2, this template doesn't support it. Please use the `Variants-and-Experimental/ASG-Puppet` for that.
- `Variants-and-Experimental/ASG-Puppet` is the current "state of the art".

I have not updated links in the README.md files in the `Old` directory, but I did for the `Configured-by-Puppet` and `Variants-and-Experimental/ASG-Puppet`. If you find any broken links, please kindly open a pull request or an issue.

Thank you :)
