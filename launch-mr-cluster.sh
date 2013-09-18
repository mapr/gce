#! /bin/bash
#
#  Script to launch a MapReduce cluster in the Google Compute Environment.
# 
# Assumptions:
#	gcutil tool is in the path
#	Master nodes run Zookeeper, CLDB and Jobtracker
#	Slave nodes run only tasktracker and fileserver
#
#	TBD : handle persistent boot disk cleanly ... with some kind
#			of command line flag
#	TBD : configure MCS and NFS on the first Master node only,
#		    or have some command line flags to control this;
#			for now, all master nodes are configured with both 
#	TBD : configure Metrics database (could be a separate server altogether)
#			or maybe a "use-head-node" flag to put webserver and
#			metrics [ and ganglia ] away from the cluster
#
#
# Things to think about
#	The cluster specification (--cluster <name>) is used as a basis
#	  for the host names themselves.  The standard practice of 
#	  using a full-qualified domain name has issues for the 
#	  gcutil tool (which expects simple hostnames only) and 
#	  DNS resolution within the cluster.  For now, we'll strip down 
#	  the cluster specification when it is used as part of a hostname
#
# Tricks
#	Pass in prepare-mapr-image.sh script as metadata ... to be used
#	  in case user selects an image WITHOUT the MapR software
#	  Downside: this prevents easy sharing of ssh keys between mapr users

PROGRAM=$0

#	NOTE: GCE_BASE may change with updates to gcutil utility. 
GCE_BASE="projects/google/global"

usage() {
  echo "
  Usage:
    $PROGRAM
       --project <GCE Project>
       --cluster <clustername>
       --machine-type <machine-type>
       --mapr-version <version, eg 1.2.3>
       --masters <num masters>
       --slaves <num slaves>
       --zone gcutil-zone
       --image image_name
	   [ --persistent-disks <nxm> # N disks of M gigabytes ]
	   [ --license-file <license to be installed> ]
   "
  echo ""
  echo "EXAMPLES"
  echo "$0 --cluster cluster.mygce.com --mapr-version 2.0.1 --masters 2 --slaves 8 --image centos-6-2-v20120621 --machine-type n1-standard-2-d"
  echo "$0 --cluster cluster.mygce.com --mapr-version 2.1.1 --masters 3 --slaves 9 --image gcel-12-04-v20121106 --machine-type n1-standard-2 --persistent-disks 4x16"
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
  --project)      project=$2  ;;
  --cluster)      cluster=$2  ;;
  --machine-type) machinetype=$2  ;;
  --mapr-version) maprversion=$2  ;;
  --masters)      nmasters=$2  ;;
  --slaves)       nslaves=$2  ;;
  --zone)         zone=$2  ;;
  --image)        image=$2 ;;
  --license-file) licenseFile=$2 ;;
  --persistent-disks) pdisk=$2 ;;
  *)
     echo "****" Bad argument:  $1
     usage
     exit  ;;
  esac
  shift 2
done

# Defaults
project=${project:-"maprtech.com:rlankenau"}
machinetype=${machinetype:-"n1-standard-2-d"}
zone=${zone:-"us-central2-a"}
licenseFile=${licenseFile:-"/Users/dtucker/Documents/MapR/LatestV2DemoLicense.txt"}

# TO BE DONE
#	Error check paramters here !!!
#		Things to remember
#			- cluster must have at least 2 nodes (one of which is a master)
#
if [ -z "${maprversion:-}" ] ; then
	echo "Must specify MapR version !!!"
 	exit 1
fi
if [ $nmasters -lt 1 ] ; then
	echo "Cluster must have at least 1 master node !!!"
 	exit 1
fi


# We have known images for the different versions, so we can pick it
# if users have specified the version.  This needs to be
# adjusted to run for ALL potential project id's.
#	TBD : we should probably check for the existance of the image
#

if [ -n "${image:-}" ] ; then
	maprimage=$image
else
	case $maprversion in 
		2.0.1)		maprimage="mapr-201-15869-trial-ubuntu-1204"  ;;
		2.1.1)		maprimage="mapr-211-17042-trial-ubuntu-1204"  ;;
		*)
			echo No image available for MapR version $maprversion; sorry
			exit 1
			;;
	esac
fi

# If the image has "mapr" in it, we'll assume it's in our project;
# otherwise, go to the base project for our image.
if [ "${maprimage%mapr*}" = ${maprimage} ] ; then
	maprimage=${GCE_BASE}/images/${maprimage}
fi



echo CHECK: ----- 
echo "	cluster $cluster"
echo "	image $maprimage"
echo "	machine $machinetype"
echo "	mapr-version $maprversion"
echo "	masters $nmasters"
echo "	slaves ${nslaves:-0}"
echo "	project $project"
echo "	zone $zone"
echo OPTIONAL: ----- 
echo "	licenseFile $licenseFile"
echo "	persistent-disks ${pdisk:-none}"
echo ----- 
echo "Proceed {y/N} ? "
read YoN
if [ -z "${YoN:-}"  -o  -n "${YoN%[yY]*}" ] ; then
 	exit 1
fi

#
# Launch the cluster
#
# Our logic is simple here ... all masters run both zookeeper and cldb.
# The mechanics of the sub-scripts make it possible to customize this
# fairly easily (for example, the first two masters also deploying
# the web-server service, etc.)
# 

# Compute the disk specifications ... 
#	N disks of size S from the pdisk parameter
ndisk="${pdisk%x*}"
dsize="${pdisk#*x}"
[ -z "${dsize:-}" -o  "${dsize:-0}" -le 0 ] && ndisk=""


# first launch the masters
master=
mm=
for i in $(seq 1 $nmasters)
do
	# hostname passed to gcutil CANNOT be FQDN ... strip off 
	# "domain" specification from cluster name
  if [ $i -lt 10 ] ; then msuffix="0${i}" ; else msuffix=${i} ; fi
  m=m${msuffix}-${cluster%%.*}
  mm=$mm' '$m
  if [ -n "$master" ]
  then
    master=$master','$m
  else
    master=$m
  fi

	# Build up the disk argument CAREFULLY ... the shell
	# addition of extra ' and " characters really confuses the
	# final invocation of gcutil
	#
	# We could be smarter about error handling, but it's safer
	# to simply ignore any disk where there is a problem creating
	# it (even if it already exists).
  if [ -n "${ndisk:-}"  -a  "${ndisk:-0}" -gt 0 ] ; then
	pdiskargs=""
	for d in $(seq 1 $ndisk) 
	do
		diskname=${m}-pdisk-${d}
		gcutil adddisk \
			$diskname \
			--project=$project \
			--zone=$zone \
			--size_gb ${dsize} 
		if [ $? -eq 0 ] ; then
			pdiskargs=${pdiskargs}' '--disk' '$diskname,mode=READ_WRITE
		fi
 	done

	instance_disks[${i}]="${pdiskargs:-}"
  fi
done

# 
# Version 1.4.1 of gcutil supports parallel spawning of instances ...
# so we can do that for all master nodes.  In the case where we
# have instance-specific arguments, we'll do a simple for loop and
# let the shell do the waiting. 
#
# Launch the slave nodes AFTER the masters are happy.
#
for m in $mm
do
  i=${m%-*}
  i=`expr ${i#m}`
#	if [ -n "$mm" ] ; then
  echo "Launching master $i ($m)"
  gcutil addinstance \
    --project=$project \
    --image=$maprimage \
    --machine_type=$machinetype \
    --zone=$zone \
	--persistent_boot_disk \
    ${instance_disks[$i]} \
    --metadata_from_file=startup-script:configure-mapr-instance.sh \
    --metadata_from_file=maprimagerscript:prepare-mapr-image.sh \
    --metadata=maprversion:$maprversion  \
    --metadata=maprpackages:zookeeper,cldb,jobtracker,fileserver,tasktracker,nfs,webserver \
    --metadata_from_file=maprlicense:$licenseFile \
    --metadata=maprmetricsserver:m01-${cluster%%.*} \
    --metadata=maprmetricsdb:maprmetrics \
    --metadata=cluster:$cluster \
    --metadata=zknodes:"$master" \
    --metadata=cldbnodes:"$master" \
    --wait_until_running \
    $m &
#	fi
done

wait


if [ ${nslaves:-0} -le 0 ] ; then
	exit 0
fi


# We could wait here for the masters to get further along
# in spinning up the ZooKeeper and CLDB services, but the
# logic in configure-mapr-instance had logic to wait up to 10 
# minutes for the Hadoop File System to come on line ...
# that should be enough.

# echo Waiting for the masters to get ready
# sleep 20

for i in $(seq 1 $nslaves)
do
  if [ $i -lt 10 ] ; then ssuffix="0${i}" ; else ssuffix=${i} ; fi
  s=s${ssuffix}-${cluster%%.*}

	# Build up the disk argument CAREFULLY ... the shell
	# addition of extra ' and " characters really confuses the
	# final invocation of gcutil
	#
	# We could be smarter about error handling, but it's safer
	# to simply ignore any disk where there is a problem creating
	# it (even if it already exists).
  if [ -n "${ndisk:-}"  -a  "${ndisk:-0}" -gt 0 ] ; then
	pdiskargs=""
	for d in $(seq 1 $ndisk) 
	do
		diskname=${s}-pdisk-${d}
		gcutil adddisk \
			$diskname \
			--project=$project \
			--zone=$zone \
			--size_gb ${dsize} 
		if [ $? -eq 0 ] ; then
			pdiskargs=${pdiskargs}' '--disk' '$diskname,mode=READ_WRITE
		fi
 	done

	instance_disks[${i}]="${pdiskargs:-}"
  fi
done


# We could definitely parallelize this at the Google Compute Engine
# layer rather than here at the shell level ... but it's not much
# of a difference in total time to spin up a cluster.

for i in $(seq 1 $nslaves)
do
	# hostname passed to gcutil CANNOT be FQDN ... strip off 
	# "domain" specification from cluster name
  if [ $i -lt 10 ] ; then ssuffix="0${i}" ; else ssuffix=${i} ; fi
  slave=s${ssuffix}-${cluster%%.*}
  echo "Launching slave $i ($slave)"
  gcutil addinstance \
    --project=$project \
    --image=$maprimage \
    --machine_type=$machinetype \
    --zone=$zone \
    ${instance_disks[$i]} \
    --metadata_from_file=startup-script:configure-mapr-instance.sh \
    --metadata_from_file=maprimagerscript:prepare-mapr-image.sh \
    --metadata=maprversion:$maprversion  \
    --metadata=maprpackages:fileserver,tasktracker \
    --metadata=maprnfsserver:m01-${cluster%%.*} \
    --metadata=maprmetricsserver:m01-${cluster%%.*} \
    --metadata=maprmetricsdb:maprmetrics \
    --metadata=cluster:$cluster \
    --metadata=zknodes:"$master" \
    --metadata=cldbnodes:"$master" \
    --wait_until_running \
    $slave  &
done

wait


echo "Cluster $cluster launched with $nmasters master(s) and $nslaves slave(s)."
echo "	Check /tmp/maprinit.log on each node to confirm proper instantiation."
echo "	MapR services should be active in a few minutes."


