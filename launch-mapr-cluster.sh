#!/bin/bash
#
#  Script to launch a MapR cluster in the Google Cloud Environment.
#   Cluster configuration defined in simple file of the form
#       ${NODE_NAME_ROOT}<index>:<packages>
#   for all the nodes you desire.  The 'mapr-' prefix is not necessary
#   for the packages. Any line that does NOT start with ${NODE_NAME_ROOT}
#   is treated as a comment. 
#
#   A sample config file is
#       node0:zookeeper,cldb,fileserver,tasktracker,nfs,webserver
#       node1:zookeeper,cldb,fileserver,tasktracker,nfs
#       node2:zookeeper,jobtracker,fileserver,tasktracker,nfs
#
#	By default, the nodes will be given hostnames equivalent to the
#	name specification (eg "node0", "node1", "node2" in the above example).
#	The base hostname can be overridden with the "--node-name" option.
#
#	Data disks default to ephemeral, but persistent disks can 
#	be requested on the command line and automatically allocated.
#
# Assumptions:
#   gcloud tool is in the PATH
#
# Tricks
#	Pass in prepare-mapr-image.sh script as metadata ... to be used
#	  in case user selects an image WITHOUT the MapR software
#	  Downside: this prevents easy sharing of ssh keys between mapr users
#

PROGRAM=$0

NODE_NAME_ROOT=node     # used in config file to define nodes for deployment

usage() {
  echo "
  Usage:
    $PROGRAM
       --cluster <clustername>
       --mapr-version <version, eg 3.1.1, 4.1.0>
       --config-file <cfg-file>
       --image image_name
       --machine-type <machine-type>
       --persistent-disks <nxm>         # N disks of M gigabytes 
       --zone zone
       [ --project <GCE Project ID>     # uses gcloud config default ]
       [ --node-name <name-prefix>      # hostname prefix for cluster nodes ]
       [ --license-file <license to be installed> ]
   "
  echo ""
  echo "EXAMPLES"
  echo "$0 --cluster ProdCluster --mapr-version 3.0.3 --config-file 3node.lst --node-name prod --image debian-7-wheezy --machine-type n1-highmem-2 --persistent-disks 4x256"
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


# Assemble the data we'll need to pass in to each node
#
# The ZK and CLDB host settings are easy, since GCE will set up
# micro-dns to make our assigned hostnames consistent across the deployed
# nodes.
#
# ResourceManager and History server nodes are necessary only for
# MapR 4.0 and later; we'll look for them for every cluster, though.
#
#	DOWNSIDE : be careful not to launch multiple clusters with the same
#	hostname defaults.
#
zknodes=`grep ^$NODE_NAME_ROOT $configFile | grep zookeeper | cut -f1 -d:`
for zkh in `echo $zknodes` ; do
	zkidx=${zkh#${NODE_NAME_ROOT}}
	
	[ -n "${nodeName:-}" ] && zkh=${nodeName}$zkidx
	if [ -n "${zkhosts:-}" ] ; then zkhosts=$zkhosts','$zkh
	else zkhosts=$zkh
	fi
done

cldbnodes=`grep ^$NODE_NAME_ROOT $configFile | grep cldb | cut -f1 -d:`
for cldbh in `echo $cldbnodes` ; do
	cldbidx=${cldbh#${NODE_NAME_ROOT}}
	
	[ -n "${nodeName:-}" ] && cldbh=${nodeName}$cldbidx
	if [ -n "${cldbhosts:-}" ] ; then cldbhosts=$cldbhosts','$cldbh
	else cldbhosts=$cldbh
	fi
done

rmnodes=`grep ^$NODE_NAME_ROOT $configFile | grep resourcemanager | cut -f1 -d:`
for rmh in `echo $rmnodes` ; do
	rmidx=${rmh#${NODE_NAME_ROOT}}

	[ -n "${nodeName:-}" ] && rmh=${nodeName}$rmidx
	if [ -n "${rmhosts:-}" ] ; then rmhosts=$rmhosts','$rmh
	else rmhosts=$rmh
	fi
done

hsnode=`grep ^$NODE_NAME_ROOT $configFile | grep historyserver | head -1 | cut -f1 -d:`
if [ -n "$hsnode" ] ; then
	hsidx=${hsnode#${NODE_NAME_ROOT}}

	[ -n "${nodeName:-}" ] && hsnode=${nodeName}$hsidx
fi

# Grab just one metrics node to run the MySQL service
metricsnode=`grep ^$NODE_NAME_ROOT $configFile | grep metrics | head -1 | cut -f1 -d:`
if [ -n "$metricsnode" ] ; then
	metricsidx=${metricsnode#${NODE_NAME_ROOT}}

	[ -n "${nodeName:-}" ] && metricsnode=${nodeName}$metricsidx
fi

# TBD 
#	Make sure there are an odd number of zookeepers and at least one CLDB


echo CHECK: -----
echo "  project-id ${project:-default}"
echo "  cluster $cluster"
echo "  mapr-version $maprversion"
echo "  config-file $configFile"
echo "     cldb: $cldbhosts"
echo "     zk:   $zkhosts"
echo "  image $maprimage"
echo "  machine $machinetype"
echo "  zone $zone"
echo OPTIONAL: -----
echo "  node-name ${nodeName:-none}"
echo "  licenseFile ${licenseFile:-none}"
echo "  persistent-disks ${pdisk:-none}"
echo -----
echo "Proceed {y/N} ? "
read YoN
if [ -z "${YoN:-}"  -o  -n "${YoN%[yY]*}" ] ; then
	exit 1
fi

# Set gcloud args based on input
[ -n "$project" ] && project_arg="--project $project"

# Only add metadata for metrics if we have Metrics configured
if [ -n "${metricsnode:-}" ] ; then
	metrics_args="maprmetricsserver=${metricsnode:-} maprmetricsdb=maprmetrics"
fi

# Only add license arg if file exists
if [ -n "${licenseFile}" ] ; then
	[ -f "${licenseFile}" ] && \
		license_args="maprlicense=${licenseFile}" 
fi

#	Since the format of each hostline is so simple (<node>:<packages>),
#	it's safer to simply parse it ourselves.

grep ^$NODE_NAME_ROOT $configFile | \
while read hostline
do
	host="${hostline%:*}"
	packages="${hostline#*:}"

	idx=${host#${NODE_NAME_ROOT}}
	[ -n "${nodeName:-}" ] && host=${nodeName}$idx

	echo "Launch $host with $packages"

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
		  startup-script=configure-mapr-instance.sh \
		  maprimagerscript=prepare-mapr-image.sh \
		  ${license_args:-} \
		--metadata \
		  maprversion=${maprversion} \
		  maprpackages=${packages//,/:} \
		  ${metrics_args:-} \
		  cluster=${cluster} \
		  zknodes=${zkhosts//,/:} \
		  cldbnodes=${cldbhosts//,/:} \
		  rmnodes=${rmhosts//,/:} \
		  hsnode=${hsnode} \
		--scopes storage-full &
done

wait


echo ""
gcloud compute instances list ${project_arg:-} --zone $zone \
	| grep ^${host%${idx}}

