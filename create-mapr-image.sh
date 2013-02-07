#! /bin/bash
#
#	leveraged from setup-image.sh
#
# Simple script to create a virtual machine instance in 
# GoogleComputeEngine with the MapR software.
#
# Initial instantiation takes about 60 seconds, then another 90-120 seconds
# for the prepare-mapr-image.sh script to do its job.
#
# For now, we include CLDB and JobTracker in the base image, 
# but not ZooKeeper (because the mechanics of the mapr-zk-internal package
# are a little difficult to handle elegantly).
#

[ $# -lt 4 ] || {
	echo "usage: $0 <new instance name> <base image>  <MapR version>  [ <zone> ]  [ <project> ]"
	echo "    example: $0 mrc-01  ubuntu-12-04-v20120912  2.1.1"
	echo "    <zone> defaults to us-central2-a, and
	echo "    <project> defaults to "maprtech.com:rlankenau"
	exit 1
}

instName=$1
baseImage=$2
maprversion=$3
GCE_ZONE=${4:-"us-central2-a"}
GCE_PROJECT=${5:-"maprtech.com:rlankenau"}

# ToBeDone
#	Images can be local to our project, or base images for the Google
# 	Compute service.  If they are the latter, we need to prepend the
#	proper suffixe so that they are found correctly.
image="projects/google/global/images/$baseImage"

# default to a simple machine type
mach=n1-standard-2-d

echo gcutil --project=$GCE_PROJECT \
	addinstance $instName \
    --metadata=image:$baseImage \
    --metadata=maprversion:$maprversion \
    --metadata=maprpackages:cldb,jobtracker,fileserver,tasktracker \
    --metadata_from_file=startup-script:prepare-mapr-image.sh \
    --zone=$GCE_ZONE \
    --machine_type=$mach \
	--image=$image \
    --wait_until_running

gcutil --project=$GCE_PROJECT \
	addinstance $instName \
    --metadata=image:$baseImage \
    --metadata=maprversion:$maprversion \
    --metadata=maprpackages:cldb,jobtracker,fileserver,tasktracker \
    --metadata_from_file=startup-script:prepare-mapr-image.sh \
    --zone=$GCE_ZONE \
    --machine_type=$mach \
	--image=$image \
    --wait_until_running

