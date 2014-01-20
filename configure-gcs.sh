#!/bin/bash
#
# Simple script to download Google's GHFS connector and configure
# it for the MapR Hadoop deployment.  
#
# The CONFIGBUCKET specification need not reference an existing 
# bucket; it is simply the default location for un-affiliated files
# accessed via the "gs://" syntax.
#
# The GCS_JARURI and GHCONFIG_URI specifications may change.  
# Check the latest documentation at the Google Developer site
# in the event that a newer release of either product is available.
#	
# Google distributes these packages as part of a larger 
# "Apache Hadoop on GCE" bundle 
# (https://developers.google.com/hadoop/setting-up-a-hadoop-cluster)
# Since the MapR cluster on GCE is set up with a different set of scripts
# (launch-mapr-cluster.sh), there's no need for this infrastructure.
# Simply deploy your cluster and then run this script on each
# cluster node or client node that will access the cluster.
#
# NOTE: 
#	The script must be run by a user with "sudo" privileges, since
#	changes are made to the contents of $MAPR_HOME.  Your GCE user
#	account will have these privileges. 
#


GCS_JARURI=https://storage.googleapis.com/hadoop-lib/gcs/gcs-connector-1.2.0.jar
GCS_JARNAME=`basename $GCS_JARURI`
if [ ! -f $HOME/$GCS_JARNAME ] ; then
	curl -o $HOME/$GCS_JARNAME $GCS_JARURI
	if [ $? -ne 0 ] ; then
		echo "Error: Unable to download $GCS_JARURI"
		exit 1
	fi
fi


GHCONFIG_URI=https://storage.googleapis.com/hadoop-tools/ghconfig/ghconfig-0.27.0.tar.gz
GHCONFIG_TARBALL=ghconfig.tar.gz
if [ ! -x $HOME/ghconfig*/ghconfig ] ; then
	curl -o $GHCONFIG_TARBALL  $GHCONFIG_URI
	if [ $? -ne 0 ] ; then
		echo "Error: Unable to download $GHCONFIG_URI"
		exit 1
	fi

	tar -C $HOME -xvf $GHCONFIG_TARBALL
	if [ ! -x $HOME/ghconfig*/ghconfig ] ; then
		echo "Error: ghconfig utility not found in $GHCONFIG_URI"
		exit 1
	fi
fi


# Metadata for this instance ... pull out details that we'll need
#
#   Note: The official release of GCE requires extra HTTP headers to
#   satisfy the metadata requests.
#
murl_top=http://metadata/computeMetadata/v1
murl_attr="${murl_top}/instance/attributes"
md_header="X-Google-Metadata-Request: True"

GCE_PROJECT=$(curl -H "$md_header" -f $murl_top/project/project-id)
CONFIGBUCKET=gsdefault

MAPR_ENV=/opt/mapr/conf/env.sh 
[ -f $MAPR_ENV ] && . $MAPR_ENV

if [ -z "${MAPR_HOME:-}" ] ; then
	echo "Error: No MapR installation found"
	exit 1
fi


if [ ! -f $MAPR_HOME/hadoop/hadoop-0.20.2/lib/$GCS_JARNAME ] ; then
	sudo cp $HOME/$GCS_JARNAME $MAPR_HOME/hadoop/hadoop-0.20.2/lib
fi

sudo $HOME/ghconfig*/ghconfig configure_ghfs \
	--hadoop_conf_dir=$MAPR_HOME/hadoop/hadoop-0.20.2/conf \
	--ghfs_jar_path=$MAPR_HOME/hadoop/hadoop-0.20.2/lib/$GCS_JARNAME \
	--system_bucket ${CONFIGBUCKET} \
	--enable_service_account_auth \
	--project_id ${GCE_PROJECT}

