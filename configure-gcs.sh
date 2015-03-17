#!/bin/bash
#
# Simple script to download Google's GHFS connector and configure
# it for the MapR Hadoop deployment.  
#
# The CONFIGBUCKET specification need not reference an existing 
# bucket; it is simply the default location for un-affiliated files
# accessed via the "gs://" syntax.
#
# The GCS_JARURI and BDCONFIG_URI specifications may change.  
# Check the latest documentation at the Google Developer site
# in the event that a newer release of either product is available.
#	
# Google distributes these packages as part of a larger 
# "bdutil" bundle (an evolution of the original "Apache Hadoop on GCE" 
# bundle)  See https://developers.google.com/hadoop/ for details.
#
# Since the MapR cluster on GCE is set up with a different set of scripts
# (launch-mapr-cluster.sh), there's no need for bdutil infrastructure.
# Simply deploy your cluster and then run this script on each
# cluster node or client node that will access the cloud storage.
#
# NOTE: 
#	The script must be run by a user with "sudo" privileges, since
#	changes are made to the contents of $MAPR_HOME.  Your GCE user
#	account will have these privileges. 
#

# Metadata for this instance ... pull out details that we'll need
#
murl_top=http://metadata/computeMetadata/v1
murl_attr="${murl_top}/instance/attributes"
md_header="Metadata-Flavor: Google"

GCE_PROJECT=$(curl -H "$md_header" -f $murl_top/project/project-id)
GCS_VERSION=1.3.3
CONFIGBUCKET=gsdefault
GCS_TEMPLATE_FILE=$HOME/gcs-core-template.xml

# Variables for this MapR installation
#
MAPR_HOME=/opt/mapr
MAPR_VERSION=`cat $MAPR_HOME/MapRBuildVersion`


# Create the template parameter file we'll merge into our
# hadoop configuration
cat > $GCS_TEMPLATE_FILE << EOF_template
<?xml version="1.0" ?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>fs.gs.project.id</name>
    <value>$GCE_PROJECT</value>
    <description>
      Google Cloud Project ID with access to configured GCS buckets.
    </description>
  </property>
  <property>
    <name>fs.gs.system.bucket</name>
    <value>$CONFIGBUCKET</value>
    <description>
      GCS bucket to use as a default bucket if fs.default.name is not a gs: uri.
    </description>
  </property>
  <property>
    <name>fs.gs.working.dir</name>
    <value>/</value>
    <description>
      The directory relative gs: uris resolve in inside of the default bucket.
    </description>
  </property>
  <property>
    <name>fs.gs.impl</name>
    <value>com.google.cloud.hadoop.fs.gcs.GoogleHadoopFileSystem</value>
    <description>The FileSystem for gs: (GCS) uris.</description>
  </property>
  <property>
    <name>fs.AbstractFileSystem.gs.impl</name>
    <value>com.google.cloud.hadoop.fs.gcs.GoogleHadoopFS</value>
    <description>The AbstractFileSystem for gs: (GCS) uris.</description>
  </property>
</configuration>

EOF_template


# Locate the Hadoop configuration and library directories
if [ ${MAPR_VERSION%%.*} -le 3 ] ; then
	HADOOP_HOME=${MAPR_HOME}/hadoop/hadoop-0.20.2
	HADOOP_CONF_DIR=${HADOOP_HOME}/conf
	HADOOP_LIB_DIR=${HADOOP_HOME}/lib

	GCS_JARNAME="gcs-connector-${GCS_VERSION}-hadoop1.jar"
else
	HADOOP_HOME="$(ls -d /opt/mapr/hadoop/hadoop-2*)"
	HADOOP_CONF_DIR=${HADOOP_HOME}/etc/hadoop
	HADOOP_LIB_DIR=${HADOOP_HOME}/share/hadoop/common/lib

	GCS_JARNAME="gcs-connector-${GCS_VERSION}-hadoop2.jar"
fi

GCS_JARURI=https://storage.googleapis.com/hadoop-lib/gcs/$GCS_JARNAME
if [ ! -f $HOME/$GCS_JARNAME ] ; then
	curl -o $HOME/$GCS_JARNAME $GCS_JARURI
	if [ $? -ne 0 ] ; then
		echo "Error: Unable to download $GCS_JARURI"
		exit 1
	fi
fi


BDCONFIG_URI=https://storage.googleapis.com/hadoop-tools/bdconfig/bdconfig-0.28.1.tar.gz
BDCONFIG_TARBALL=bdconfig.tar.gz
if [ ! -x $HOME/bdconfig*/bdconfig ] ; then
	curl -o $BDCONFIG_TARBALL  $BDCONFIG_URI
	if [ $? -ne 0 ] ; then
		echo "Error: Unable to download $BDCONFIG_URI"
		exit 1
	fi

	tar -C $HOME -xf $BDCONFIG_TARBALL
	if [ ! -x $HOME/bdconfig*/bdconfig ] ; then
		echo "Error: bdconfig utility not found in $BDCONFIG_URI"
		exit 1
	fi
fi


MAPR_ENV=/opt/mapr/conf/env.sh 
[ -f $MAPR_ENV ] && . $MAPR_ENV

if [ -z "${MAPR_HOME:-}" ] ; then
	echo "Error: No MapR installation found"
	exit 1
fi


if [ ! -f $HADOOP_LIB_DIR/$GCS_JARNAME ] ; then
	sudo cp $HOME/$GCS_JARNAME $HADOOP_LIB_DIR
fi


sudo $HOME/bdconfig*/bdconfig merge_configurations \
	--configuration_file ${HADOOP_CONF_DIR}/core-site.xml \
	--source_configuration_file $GCS_TEMPLATE_FILE \
	--create_if_absent \
	--noclobber

