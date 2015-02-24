#!/bin/bash
#
#  Script to remove an lanched MapR cluster in the Google Cloud Environment.
#   --config-file --persistent-disks --node-name should be consistent with 
#  the ones that launch script used.
#
#	By default, the nodes will be given hostnames equivalent to the
#	name specification (eg "node0", "node1", "node2" in the above example).
#	The base hostname can be overridden with the "--node-name" option.
#
#	Node boot disks default to persistent; For ephemeral boot disks,
#	use the "--persistent-boot" option (set to false).
#
#	Data disks default to ephemeral, but persistent disks can 
#	be requested on the command line and automatically allocated.
#
# Assumptions:
#   gcutil tool is in the PATH
#
#

PROGRAM=$0

NODE_NAME_ROOT=node     # used in config file to define nodes for deployment

usage() {
  echo "
  Usage:
    $PROGRAM
       --project <GCE Project>
       --config-file <cfg-file>         # Need to the same as lanch-mapr-cluster.sh used
       --persistent-disks <nxm>         # N disks of M gigabytes, need to the same as lanch-mapr-cluster.sh used
       --zone gcutil-zone
      [ --node-name <name-prefix>      # hostname prefix for cluster nodes ]
   "
  echo ""
  echo "EXAMPLES"
  echo "$0 --config-file 3node.lst --node-name test --zone us-central1-f --persistent-disks 4x256"
}


	# Build up the disk argument CAREFULLY ... the shell
	# addition of extra ' and " characters really confuses the
	# final invocation of gcutil
	#
	# We could be smarter about error handling, but it's safer
	# to simply ignore any disk where there is a problem creating
	# it (since the most common error during our development was
	# that the disk had already been created).
delete_persistent_data_disks() {
	targetNode=$1
		# Compute the disk specifications ... 
		#	N disks of size S from the pdisk parameter
	ndisk="${pdisk%x*}"
	dsize="${pdisk#*x}"
	[ -z "${dsize:-}" -o  "${dsize:-0}" -le 0 ] && ndisk=""

	[ -z "${targetNode}" ] && return 1
	[ -z "${ndisk:-}"  -o  "${ndisk:-0}" -le 0 ] && return 1

	pdisk_args=""
	for d in $(seq 1 $ndisk) 
	do
		diskname=${targetNode}-pdisk-${d}

		echo "Delete pdisk ${diskname}"
		gcloud compute disks delete -q \
			$diskname \
			--project $project \
			--zone $zone
 	done
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
  --config-file)  configFile=$2  ;;
  --node-name)    nodeName=$2  ;;
  --project)      project=$2  ;;
  --zone)         zone=$2  ;;
  --persistent-disks)      pdisk=$2  ;;
  *)
     echo "****" Bad argument:  $1
     usage
     exit  ;;
  esac
  shift 2
done
echo ""


grep ^$NODE_NAME_ROOT $configFile | \
while read hostline
do
	host="${hostline%:*}"
	idx=${host#${NODE_NAME_ROOT}}
	[ -n "${nodeName:-}" ] && host=${nodeName}$idx

	echo "Remove instance $host"
	gcloud compute instances delete -q \
		--project $project \
		--keep-disks boot \
		--zone $zone \
		$host

	echo "Remove disk $host"
	gcloud compute disks delete -q \
		--project $project \
		--zone $zone \
		$host

	if [ -n "${pdisk:-}" ] ; then
		echo ""
		echo " Delete persistent data volumes (${host}-pdisk-*)"
		delete_persistent_data_disks $host
	fi
done

wait

