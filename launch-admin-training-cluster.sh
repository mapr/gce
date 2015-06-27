#!/bin/bash
#
#  Script to launch a cluster in the Google Cloud Environment for
#  use in the On-Demand Training regiman.
#
#  This is simply a short-circuit of the usual launch-mapr-cluster.sh
#  logic, since all that needs to be done is initialize the nodes for
#  manual software installation/configuration.   We have kept the
#  same basic structure just to simplify the user experience.
#
# Assumptions:
#   gcloud tool is in the PATH
#
#

PROGRAM=$0

NODE_NAME_ROOT=node     # used in config file to define nodes for deployment

usage() {
  echo "
  Usage:
    $PROGRAM
       --config-file <cfg-file>
       --image image_name
       --machine-type <machine-type>
       --persistent-disks <nxm>         # N disks of M gigabytes 
       --zone zone
       [ --project <GCE Project ID>     # uses gcloud config default ]
       [ --node-name <name-prefix>      # hostname prefix for cluster nodes ]
   "
  echo ""
  echo "EXAMPLES"
  echo "$0 --config-file 3node.lst --node-name odt --image centos-6  --machine-type n1-highmem-2 --persistent-disks 2x256"
}


	# Build up the disk argument CAREFULLY ... the shell
	# addition of extra ' and " characters really confuses the
	# final invocation of gcloud
	#
	# We could be smarter about error handling, but it's safer
	# to simply ignore any disk where there is a problem creating
	# it (since the most common error during our development was
	# that the disk had already been created).
create_persistent_data_disks() {
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

		gcloud compute disks list ${project_arg:-} --zone $zone \
			--regexp "$diskname" \
			| grep -q $diskname

		if [ $? -eq 0 ] ; then
			pdisk_args=${pdisk_args}' '--disk' 'name=$diskname' 'mode=rw
		else
			gcloud compute disks create \
				$diskname \
				${project_arg:-} \
				--zone $zone \
				--size ${dsize}GB
			if [ $? -eq 0 ] ; then
				pdisk_args=${pdisk_args}' '--disk' 'name=$diskname' 'mode=rw
			fi
		fi
 	done

	export pdisk_args
}


#
#  MAIN
#
if [ $# -lt 4 ]
then
  usage
  exit 1
fi

while [ $# -gt 0 ]
do
  case $1 in
  --cluster)      cluster=$2  ;;
  --mapr-version) maprversion=$2  ;;
  --config-file)  configFile=$2  ;;
  --node-name)    nodeName=$2  ;;
  --project)      project=$2  ;;
  --zone)         zone=$2  ;;
  --image)        image=$2 ;;
  --machine-type) machinetype=$2  ;;
  --license-file) licenseFile=$2 ;;
  --persistent-disks) pdisk=$2 ;;
  *)
     echo "****" Bad argument:  $1
     usage
     exit  ;;
  esac
  shift 2
done
echo ""


# Defaults
maprversion=${maprversion:-"4.1.0"}
machinetype=${machinetype:-"n1-standard-2"}
zone=${zone:-"us-central1-b"}

if [ -n "${image:-}" ] ; then
	maprimage=$image
else
	echo "ERROR: No image specified; aborting cluster creation"
	exit 1
fi

if [ "${machinetype%-d}" = "${machinetype}" ] ; then
	if [ -z "${pdisk:-}" ] ; then
		echo "ERROR: No persistent disks specified for diskless machine type ($machinetype);"
		echo "       aborting cluster creation"
		exit 1
	fi
fi

# TBD 
#	Validate the presense/accessibility of the image


# TBD 
#	Error check input parameters


echo CHECK: -----
echo "  project-id ${project:-default}"
echo "  config-file $configFile"
echo "  image $maprimage"
echo "  machine $machinetype"
echo "  zone $zone"
echo OPTIONAL: -----
echo "  node-name ${nodeName:-none}"
echo "  persistent-disks ${pdisk:-none}"
echo -----
echo "Proceed {y/N} ? "
read YoN
if [ -z "${YoN:-}"  -o  -n "${YoN%[yY]*}" ] ; then
	exit 1
fi

# Set gcloud args based on input
[ -n "$project" ] && project_arg="--project $project"

#	Since the format of each hostline is so simple (<node>:<packages>),
#	it's safer to simply parse it ourselves.

grep ^$NODE_NAME_ROOT $configFile | \
while read hostline
do
	host="${hostline%:*}"
	packages="${hostline#*:}"

	idx=${host#${NODE_NAME_ROOT}}
	[ -n "${nodeName:-}" ] && host=${nodeName}$idx

	echo "Launch $host"

	if [ -n "${pdisk:-}" ] ; then
		echo ""
		echo "   Creating persistent data volumes first ($pdisk)"
		create_persistent_data_disks $host
			# Side effect ... pdisk_args is set 
			#
			# An empty "pdisk_args" implies failed storage creation ...
			# so don't proceed with instance creation.
		[ -z "$pdisk_args" ] && continue
	fi

	gcloud compute instances create $host \
		${project_arg:-} \
		--image $maprimage \
		--machine-type $machinetype \
		--zone $zone \
		${pdisk_args:-} \
		--metadata-from-file \
		  startup-script=prepare-mapr-image.sh \
		--metadata \
		  maprversion=${maprversion} \
		  maprpackages=none \
		--scopes storage-full &
done

wait


echo ""
gcloud compute instances list ${project_arg:-} --zone $zone \
	| grep ^${host%${idx}}

