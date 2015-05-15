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
	echo "    example: $0 mrc-01  ubuntu-12-04  4.0.2"
	echo "    <zone> defaults to us-central1-a, and"
	echo "    <project> defaults to value stored with 'gcloud config'"
	exit 1
}

instName=$1
baseImage=$2
maprversion=$3
GCE_ZONE=${4:-"us-central1-a"}

if [ -n "${5:-}" ] ; then
	GCE_PROJECT=${5:-}
else
	GCE_PROJECT=`gcloud config list | grep "^project" | awk '{print $NF}'`
fi



# ToBeDone
#	Images can be local to our project, or base images for the Google
# 	Compute service.  If they are the latter, we need to prepend the
#	proper suffixe so that they are found correctly.
image="projects/google/global/images/$baseImage"

# default to a simple machine type
mach=n1-standard-2

echo gcloud compute --project=$GCE_PROJECT \
	instances create $instName \
    --metadata \
	  image=$baseImage \
      maprversion=$maprversion \
      maprpackages=fileserver \
    --metadata-from-file \
	  startup-script=prepare-mapr-image.sh \
    --zone=$GCE_ZONE \
    --machine-type=$mach \
	--image=$baseImage 

gcloud compute --project=$GCE_PROJECT \
	instances create $instName \
    --metadata \
	  image=$baseImage \
      maprversion=$maprversion \
      maprpackages=fileserver \
    --metadata-from-file \
	  startup-script=prepare-mapr-image.sh \
    --zone=$GCE_ZONE \
    --machine-type=$mach \
	--image=$baseImage 

