# get-instances

A couple shell scripts to fetch a list of AMIs from AWS and build "Versions" parameter and "AMI" map for Brocade vRouter and vADC CloudFormation templates.

Scripts seem to work fine now, at least when run from an Amazon Linux EC2 instance with appropriate IAM permissions.

Caveats:

- These scripts will also return AMIs for versions that are "no longer available" on Marketplace. I couldn't see any difference between what an "available" and "no longer available" AMI looks like in "aws ec2 describe-images" output. If you know how I can tell between them, please let me know.
- Version numbers look a bit ugly without dots, e.g., Version "4.2" is listed as "42". I really wanted to make it look proper, but again couldn't find a way around CloudFormation's limitation on key names in "Mappings" maps. It only allows alphanumerics. :(

Scripts do the following:
- Query list of AWS regions.
- Go through the list of regions, and check if there's a cache file for a region from old run.
- If there's a file, contents are used to produce output.
- If there's no file for one or more regions, query AWS for the AMIs, and cache results
- Once done with cache files, process them and produce the results.

Scripts accept "-h|-?" for help, or "-f" to force re-creation of all cache files.

If you need to re-build cache for particular region, just delete the cache file for that region. It should be fairly self-evident what region each cache file corresponds to.

Here's an example of a run:

```
[ec2-user@ip-172-31-29-32 ~]$ ./vR-amis.sh 
Querying region: ap-south-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: eu-west-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: ap-southeast-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: ap-southeast-2
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: eu-central-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: ap-northeast-2
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: ap-northeast-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: us-east-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: sa-east-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: us-west-1
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.
Querying region: us-west-2
Cached contents found for this region; re-run this script as "./vR-amis.sh -f" to force update.


Cut and paste the output below into your CloudFormation template:
=================================================================

  "Parameters" : {
    "vRVers" : {
      "Description" : "Please select vRouter version:",
      "Type" : "String",
      "Default" : "42R1B",
      "AllowedValues" : [
        "40R1",
        "41R2B",
        "41R3B",
        "42R1B"
      ],
      "ConstraintDescription" : "Must be a valid vRouter version"
    }
  }

  "Mappings" : {
    "vRAMI" : {
      "eu-west-1" : { "40R1" : "ami-43cd6830", "41R2B" : "ami-1e5efc6d", "41R3B" : "ami-e155d592", "42R1B" : "ami-6a59cf19" },
      "ap-southeast-1" : { "40R1" : "ami-a3c203c0", "41R2B" : "ami-3769aa54", "41R3B" : "ami-97d207f4", "42R1B" : "ami-88ad7ceb" },
      "ap-southeast-2" : { "40R1" : "ami-f26e3791", "41R2B" : "ami-cc8cd7af", "41R3B" : "ami-0b9fbc68", "42R1B" : "ami-c5ac83a6" },
      "eu-central-1" : { "40R1" : "ami-eacad886", "41R2B" : "ami-10bba77c", "41R3B" : "ami-4114f52e", "42R1B" : "ami-3642ae59" },
      "ap-northeast-2" : { "41R2B" : "ami-7dad6313", "41R3B" : "ami-7d1ad313", "42R1B" : "ami-93a06bfd" },
      "ap-northeast-1" : { "40R1" : "ami-df7351b1", "41R2B" : "ami-6100350f", "41R3B" : "ami-a7f2e2c9", "42R1B" : "ami-772ccf16" },
      "us-east-1" : { "40R1" : "ami-dacf8bb0", "41R2B" : "ami-bfb7e3d5", "41R3B" : "ami-d79a8dbd", "42R1B" : "ami-e8bb4c85" },
      "sa-east-1" : { "40R1" : "ami-0817ad64", "41R2B" : "ami-86b433ea", "41R3B" : "ami-5c63ec30", "42R1B" : "ami-143eb678" },
      "us-west-1" : { "40R1" : "ami-1cd2bc7c", "41R2B" : "ami-dae18aba", "41R3B" : "ami-cd601cad", "42R1B" : "ami-342a5154" },
      "us-west-2" : { "40R1" : "ami-bdddcddc", "41R2B" : "ami-84abb4e5", "41R3B" : "ami-7fb5411f", "42R1B" : "ami-32867852" }
    }
  }

=================================================================
```

Help:

```
[ec2-user@ip-172-31-29-32 ~]$ ./vADC-amis.sh -h
This script queries AWS for AMI IDs of Brocade Traffic Manager in all regions, and prints the respective
"Parameters" and "Mappings" sections for CloudFormation template.

When run, script checks for existence of per-region cached result files and re-uses contents, unless
the script was executed with the "-f" parameter, in which case AWS is re-queried (takes long time).

Usage: ./vADC-amis.sh [-f]
```

