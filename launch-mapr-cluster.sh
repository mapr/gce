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
#	Node boot disks default to persistent; For ephemeral boot disks,
#	use the "--persistent-boot" option (set to false).
#
#	Data disks default to ephemeral, but persistent disks can 
#	be requested on the command line and automatically allocated.
#
# Assumptions:
#   gcutil tool is in the PATH
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
       --project <GCE Project>
       --cluster <clustername>
       --mapr-version <version, eg 2.1.3, 3.0.1>
	   --config-file <cfg-file>
       --image image_name
       --machine-type <machine-type>
       --zone gcutil-zone
       [ --node-name <name-prefix>      # hostname prefix for cluster nodes ]
       [ --persistent-boot [TRUE|false] # persistent storage for boot device ]
       [ --persistent-disks <nxm>       # N disks of M gigabytes ]
       [ --license-file <license to be installed> ]
   "
  echo ""
  echo "EXAMPLES"
  echo "$0 --cluster TestCluster --mapr-version 2.0.1 --config-file 10node.lst --node-name MyTest --image centos-6-v20130723 --machine-type n1-standard-2-d"
  echo "$0 --cluster ProdCluster --mapr-version 2.1.3.2 --config-file 3node.lst --node-name prod --image debian-7-wheezy-v20130723 --machine-type n1-highmem-2 --persistent-disks 4x64"
}


	# Build up the disk argument CAREFULLY ... the shell
	# addition of extra ' and " characters really confuses the
	# final invocation of gcutil
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

		gcutil listdisks --project=$project --zone=$zone \
			--format=names --filter="name eq $diskname" \
			| grep -q $diskname

		if [ $? -eq 0 ] ; then
			pdisk_args=${pdisk_args}' '--disk' '$diskname,mode=READ_WRITE
		else
			gcutil adddisk \
				$diskname \
				--project=$project \
				--zone=$zone \
				--size_gb ${dsize} 
			if [ $? -eq 0 ] ; then
				pdisk_args=${pdisk_args}' '--disk' '$diskname,mode=READ_WRITE
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
  --persistent-boot) pboot=$2 ;;
  --persistent-disks) pdisk=$2 ;;
  *)
     echo "****" Bad argument:  $1
     usage
     exit  ;;
  esac
  shift 2
done


# Defaults
project=${project:-"maprtt"}
maprversion=${maprversion:-"2.1.3.2"}
machinetype=${machinetype:-"n1-standard-2-d"}
zone=${zone:-"us-central1-b"}
licenseFile=${licenseFile:-"/Users/dtucker/Documents/MapR/licenses/LatestDemoLicense-M5.txt"}
pboot=${pboot:-"true"}

if [ -n "${image:-}" ] ; then
	maprimage=$image
else
	echo "No image specified; aborting cluster creation"
	exit 1
fi

# If the image has "mapr" in it, we'll assume it's in our project;
# otherwise, look it up.
#	NOTE: this logic is not necessary as of vbeta15 of the gcutil command
#		if [ "${maprimage%mapr*}" = ${maprimage} ] ; then
#			img=`gcutil --project $project listimages --old_images | grep $maprimage | awk '{print $2}'`
#			if [ -n "${img}" ] ; then
#				maprimage=$img
#			else
#				echo "Image $maprimage not found; aborting cluster creation"
#				exit 1
#			fi
#		fi

# TBD 
#	Validate the presense/accessibility of the image


# TBD 
#	Error check input parameters


# Assemble the data we'll need to pass in to each node
#
# The ZK and CLDB host settings are easy, since GCE will set up
# micro-dns to make our assigned hostnames consistent across the deployed
# nodes.
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

# Grab just one metrics node to run the MySQL service
metricsnode=`grep ^$NODE_NAME_ROOT $configFile | grep metrics | head -1 | cut -f1 -d:`
if [ -n "$metricsnode" ] ; then
	metricsidx=${metricsnode#${NODE_NAME_ROOT}}

	[ -n "${nodeName:-}" ] && metricsnode=${nodeName}$metricsidx
fi

# TBD 
#	Make sure there are an odd number of zookeepers and at least one CLDB


echo CHECK: -----
echo "  project $project"
echo "  cluster $cluster"
echo "  mapr-version $maprversion"
echo "  config-file $configFile"
echo "     cldb: $cldbhosts"
echo "     zk:   $zkhosts"
echo "  image $maprimage"
echo "  persistent-boot-disk ${pboot}"
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


# Only add metadata for metrics if we have Metrics configured
if [ -n "${metricsnode:-}" ] ; then
	metrics_args="--metadata=maprmetricsserver:${metricsnode:-} --metadata=maprmetricsdb:maprmetrics"
fi

# Add persistent boot arg if necessary
if [ -n "${pboot}" ] ; then
	[ "${pboot}" = "true" ] && pboot_args="--persistent_boot_disk"
fi

#	Since the format of each hostline is so simple (<node>:<packages>),
#	it's safer to simply parse it ourselves.

grep ^$NODE_NAME_ROOT $configFile | \
while read hostline
do
set -x
	host="${hostline%:*}"
	packages="${hostline#*:}"

	idx=${host#${NODE_NAME_ROOT}}
	[ -n "${nodeName:-}" ] && host=${nodeName}$idx

	echo "Launch $host with $packages"

	if [ -n "${pdisk:-}" ] ; then
		echo ""
		echo "   Creating persistent data volumes first (pdisk)"
		create_persistent_data_disks $host
			# Side effect ... pdisk_args is set 
	fi

	gcutil addinstance \
		--project=$project \
		--image=$maprimage \
		--machine_type=$machinetype \
		--zone=$zone \
		${pboot_args:-} \
		${pdisk_args:-} \
		--metadata_from_file="startup-script:configure-mapr-instance.sh" \
		--metadata_from_file="maprimagerscript:prepare-mapr-image.sh" \
		--metadata="maprversion:${maprversion}"  \
		--metadata="maprpackages:${packages}" \
		--metadata_from_file="maprlicense:${licenseFile}" \
		${metrics_args:-} \
		--metadata="cluster:${cluster}" \
		--metadata="zknodes:${zkhosts}" \
		--metadata="cldbnodes:${cldbhosts}" \
		--wait_until_running \
    $host &
done

wait

