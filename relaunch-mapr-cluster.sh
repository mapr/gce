#!/bin/bash
#
#  Script to relaunch a MapR cluster on Google Cloud intances that
#  have been shut down.   Google Cloud does not have the "stopped"
#  concept for instances, so once nodes are shut down there is
#  no way to restart them short of
#	deleteinstance
#	runinstance
#
# Assumptions:
#	instances were created with persistent boot disks and data disks
#		(this is the default for Google Cloud as of 2014)
#	persistent boot disk is named <hostname> (again, the default)
#   gcutil tool is in the PATH
#
# Remember:
#	The nodenames must start with lower case leters, so the cluster
#	name is often the wrong thing to use as a base for the hostnames.
#		Always use the "--node-name" option !
#

PROGRAM=$0

NODE_NAME_ROOT=node     # used in config file to define nodes for deployment

usage() {
  echo "
  Usage:
    $PROGRAM
       --project <GCE Project>
       --machine-type <machine-type>
       --zone gcutil-zone
       --node-name <name-prefix>    # hostname prefix for cluster nodes 
       [ --cluster <clustername> ]  # unnecessary, but included for parallelism
   "
  echo ""
  echo "EXAMPLES"
  echo "$0 --project <MyProject> --node-name prod"
}


list_cluster_nodes() {
	clstr=$1

	cluster_nodes=""
	for n in $(gcloud compute instances list --project $project \
		--regexp ".*${clstr}[0-9]+" | sort) 
	do
		nodename=`basename $n`

			# A bit of a kludge to make sure we only work
			# on OUR cluster nodes ... and it still can fail 
			# if there is a "MapR" and a "MapRTech" cluster
		if [ ${nodename#${clstr}} != ${nodename} ] ; then 
			[ -z $zone ] && zone=${n%%/*}
			cluster_nodes="${cluster_nodes} $nodename"
		fi
 	done

	export cluster_nodes
}

	# Build up the disk argument CAREFULLY ... the shell
	# addition of extra ' and " characters really confuses the
	# final invocation of gcutil
	#
list_persistent_data_disks() {
	targetNode=$1
		# Compute the disk specifications ... 
		#	N disks of size S from the pdisk parameter

	pdisk_args=""
	for d in $(gcloud compute disks list --project $project --zone $zone \
		--regexp ".*-pdisk-[1-9]") 
	do
		diskname=`basename $d`
		[ ${diskname#${targetNode}} = ${diskname} ] && continue

		pdisk_args=${pdisk_args}' '--disk' 'name=$diskname mode=rw
 	done

	export pdisk_args
}


#
#  MAIN
#
if [ $# -lt 3 ]
then
  usage
  exit 1
fi

while [ $# -gt 0 ]
do
  case $1 in
  --cluster)      cluster=$2  ;;
  --project)      project=$2  ;;
  --machine-type) machinetype=$2  ;;
  --node-name)    nodeName=$2  ;;
  --zone)         zone=$2  ;;
  *)
     echo "****" Bad argument:  $1
     usage
     exit  ;;
  esac
  shift 2
done


# Defaults
project=${project:-"maprtt"}
machinetype=${machinetype:-"n1-standard-2"}
nodeName=${nodeName:-$NODE_NAME_ROOT}
pboot=${pboot:-"true"}


list_cluster_nodes $nodeName

if [ -z "${cluster_nodes}" ] ; then
	echo "ERROR: no nodes found with base name $nodeName"
	exit 1
fi

echo CHECK: -----
echo "  project $project"
echo "  cluster $cluster"
echo "  machine $machinetype"
echo "  node-name ${nodeName:-none}"
echo -----
echo ""
echo "NODES: ---- (all instances will be deleted and relaunched in zone $zone)"
echo "  $cluster_nodes"
echo ""

echo -----
echo "Proceed {y/N} ? "
read YoN
if [ -z "${YoN:-}"  -o  -n "${YoN%[yY]*}" ] ; then
	exit 1
fi

echo ""
echo "Deleting instances.."
# First, delete the old instances
gcloud compute instances delete $cluster_nodes \
	--project $project \
	--zone $zone \
	--keep-disks boot \
	--quiet

echo ""
echo "Adding back instances.."
# Then, add them back
for host in $cluster_nodes 
do
	list_persistent_data_disks $host
			# Side effect ... pdisk_args is set 

	gcloud compute instances create $host \
		--project $project \
		--machine-type $machinetype \
		--zone $zone \
		--disk name=$host mode=rw boot=yes \
		${pdisk_args:-} \
		--scopes storage-full &
done

wait

echo ""
echo "$nodeName nodes restarted; cluster ${cluster:-${nodeName}} relaunched !!!"
