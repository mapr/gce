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

if [ $# -lt 4 ]
then
	echo "usage: $0 <new instance name> <base image>  <MapR version>  [ <zone> ]  [ <project> ]"
	echo "    example: $0 mrc-01  ubuntu-12-04  2.1.1"
	echo "    <zone> defaults to us-central1-a, and"
	echo "    <project> defaults to 'maprtech.com:rlankenau'"
	exit 1
fi

instName=$1

# TODO:
#   Images can be local to our project, or base images for the Google
#   Compute service.
baseImage=$2
maprversion=$3
GCE_ZONE=${4:-"us-central1-a"}
GCE_PROJECT=${5:-"maprtech.com:rlankenau"}

# default to a simple machine type
mach=n1-standard-2

echo gcloud compute --project $GCE_PROJECT \
	instances create $instName \
    --metadata \
        image=$baseImage \
        maprversion=$maprversion \
        maprpackages=cldb,jobtracker,leserver,tasktracker \
    --metadata-from-file \
        startup-script=prepare-mapr-image.sh \
    --zone $GCE_ZONE \
    --machine-type $mach \
	--image $baseImage

gcloud compute --project $GCE_PROJECT \
	instances create $instName \
    --metadata \
        image=$baseImage \
        maprversion=$maprversion \
        maprpackages=cldb,jobtracker,fileserver,tasktracker \
    --metadata-from-file \
        startup-script=prepare-mapr-image.sh \
    --zone $GCE_ZONE \
    --machine-type $mach \
	--image $baseImage

