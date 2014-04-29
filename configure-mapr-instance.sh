#! /bin/bash
#
# Script attached to a GoogleComputeEngine addinstance operation
# to customize a mapr cluster node off of a default mapr image.
#		SIZE LIMIT : 32K
#
# Starting Conditions  (generated by maprimagerscript if necessary)
#	The image has the correct MapR repository links in place
#	The image has ssh public key functionality enabled
#	The image has ntp installed and running (all cluster nodes see same time)
#	The image has JAVA installed
#
# Metadata ... see MapR_metadata.txt

# Allow a little time for the network and instantiation processes to settle.
sleep 3

# Metadata for this instance ... pull out details that we'll need
#
murl_top=http://metadata/computeMetadata/v1
murl_attr="${murl_top}/instance/attributes"
md_header="X-Google-Metadata-Request: True"

THIS_FQDN=$(curl -H "$md_header" -f $murl_top/instance/hostname)
if [ -z "${THIS_FQDN}" ] ; then
	THIS_HOST=${THIS_FQDN/.*/}
else
	THIS_HOST=`/bin/hostname`
fi

THIS_IMAGE=$(curl -H "$md_header" -f $murl_attr/image)    # name of initial image loaded here
GCE_PROJECT=$(curl -H "$md_header" -f $murl_top/project/project-id) 

MAPR_HOME=$(curl -H "$md_header" -f $murl_attr/maprhome)	# software installation directory
MAPR_HOME=${MAPR_HOME:-"/opt/mapr"}
MAPR_UID=$(curl -H "$md_header" -f $murl_attr/mapruid)
MAPR_UID=${MAPR_UID:-"2000"}
MAPR_USER=$(curl -H "$md_header" -f $murl_attr/mapruser)
MAPR_USER=${MAPR_USER:-"mapr"}
MAPR_GROUP=$(curl -H "$md_header" -f $murl_attr/maprgroup)
MAPR_GROUP=${MAPR_GROUP:-"mapr"}
MAPR_PASSWD=$(curl -H "$md_header" -f $murl_attr/maprpasswd)
MAPR_PASSWD=${MAPR_PASSWD:-"MapR"}

MAPR_IMAGER_SCRIPT=$(curl -H "$md_header" -f $murl_attr/maprimagerscript)
MAPR_VERSION=$(curl -H "$md_header" $murl_attr/maprversion)
MAPR_PACKAGES=$(curl -H "$md_header" -f $murl_attr/maprpackages)
MAPR_LICENSE=$(curl -H "$md_header" -f $murl_attr/maprlicense)
MAPR_NFS_SERVER=$(curl -H "$md_header" -f $murl_attr/maprnfsserver)

MAPR_METRICS_DEFAULT=metrics
MAPR_METRICS_SERVER=$(curl -H "$md_header" -f $murl_attr/maprmetricsserver)
MAPR_METRICS_DB=$(curl -H "$md_header" -f $murl_attr/maprmetricsdb)
MAPR_METRICS_DB=${MAPR_METRICS_DB:-$MAPR_METRICS_DEFAULT}

MAPR_DISKS=""
MAPR_DISKS_PREREQS="fileserver"
#	if the PREREQ packages (comma-separated list) are installed, 
#	then we MUST find some disks to use and configure them properly 
#	... otherwise this provisioning script will return an error.

cluster=$(curl -H "$md_header" -f $murl_attr/cluster)
zknodes=$(curl -H "$md_header" -f $murl_attr/zknodes)  
cldbnodes=$(curl -H "$md_header" -f $murl_attr/cldbnodes)  

restore_only=$(curl -H "$md_header" -f $murl_attr/maprrestore)  
restore_only=${restore_only:-false}
restore_hostid=$(curl -H "$md_header" -f $murl_attr/maprhostid)

# A few other directories for our distribution
MAPR_HADOOP_DIR=${MAPR_HOME}/hadoop/hadoop-0.20.2

LOG=/tmp/configure-mapr-instance.log

# Make sure sbin tools are in PATH
PATH=/sbin:/usr/sbin:$PATH

# Identify the install command, since we'll do it a lot.
# If we don't find something rational, bail out
if which dpkg &> /dev/null  ; then
	INSTALL_CMD="apt-get install -y --force-yes"
	UNINSTALL_CMD="apt-get purge -y --force-yes"
elif which rpm &> /dev/null ; then
	INSTALL_CMD="yum install -y"
	UNINSTALL_CMD="yum remove -y"
else
	echo "Unable to identify software installation command" >> $LOG
	echo "Cannot continue" >> $LOG
	exit 1
fi


# Helper utility to log the commands that are being run and
# save any errors to a log file
#	BE CAREFUL ... this function cannot handle command lines with
#	their own redirection.

c() {
    echo $* >> $LOG
    $* || {
	echo "============== $* failed at "`date` >> $LOG
	exit 1
    }
}

# Helper utility to update ENV settings in env.sh (replicated in 
# prepare-mapr-image.sh).  WILL NOT override existing settings
#
MAPR_ENV_FILE=$MAPR_HOME/conf/env.sh
function update-env-sh()
{
	[ -z "${1:-}" ] && return 1
	[ -z "${2:-}" ] && return 1

	AWK_FILE=/tmp/ues$$.awk
	cat > $AWK_FILE << EOF_ues
/^#export ${1}=/ {
	getline
	print "export ${1}=$2"
}
{ print }
EOF_ues

	cp -p $MAPR_ENV_FILE ${MAPR_ENV_FILE}.configure_save
	awk -f $AWK_FILE ${MAPR_ENV_FILE} > ${MAPR_ENV_FILE}.new
	[ $? -eq 0 ] && mv -f ${MAPR_ENV_FILE}.new ${MAPR_ENV_FILE}
}

#
# Again, this function should match that in prepare-mapr-instance.sh
#
function add_mapr_user() {
	echo Adding/configuring mapr user >> $LOG
	id $MAPR_USER &> /dev/null
	[ $? -eq 0 ] && return $? ;

	echo "useradd -u $MAPR_UID -c MapR -m -s /bin/bash" >> $LOG
	useradd -u $MAPR_UID -c "MapR" -m -s /bin/bash $MAPR_USER 2> /dev/null
	if [ $? -ne 0 ] ; then
			# Assume failure was dup uid; try with default uid assignment
		echo "useradd returned $?; trying auto-generated uid" >> $LOG
		useradd -c "MapR" -m -s /bin/bash $MAPR_USER
	fi

	if [ $? -ne 0 ] ; then
		echo "Failed to create new user $MAPR_USER {error code $?}"
		return 1
	else
		passwd $MAPR_USER << passwdEOF > /dev/null
$MAPR_PASSWD
$MAPR_PASSWD
passwdEOF

	fi

		# Create sshkey for $MAPR_USER (must be done AS MAPR_USER)
	su $MAPR_USER -c "mkdir ~${MAPR_USER}/.ssh ; chmod 700 ~${MAPR_USER}/.ssh"
	su $MAPR_USER -c "ssh-keygen -q -t rsa -f ~${MAPR_USER}/.ssh/id_rsa -P '' "
	su $MAPR_USER -c "cp -p ~${MAPR_USER}/.ssh/id_rsa ~${MAPR_USER}/.ssh/id_launch"
	su $MAPR_USER -c "cp -p ~${MAPR_USER}/.ssh/id_rsa.pub ~${MAPR_USER}/.ssh/authorized_keys"
	su $MAPR_USER -c "chmod 600 ~${MAPR_USER}/.ssh/authorized_keys"
		
		# TBD : copy the key-pair used to launch the instance directly
		# into the mapr account to simplify connection from the
		# launch client.
	MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`

		# Enhance the login with rational stuff
    cat >> $MAPR_USER_DIR/.bashrc << EOF_bashrc

CDPATH=.:$HOME
export CDPATH

# PATH updates based on settings in MapR env file
MAPR_HOME=${MAPR_HOME:-/opt/mapr}
MAPR_ENV=\${MAPR_HOME}/conf/env.sh
[ -f \${MAPR_ENV} ] && . \${MAPR_ENV} 
[ -n "\${JAVA_HOME}:-" ] && PATH=\$PATH:\$JAVA_HOME/bin
[ -n "\${MAPR_HOME}:-" ] && PATH=\$PATH:\$MAPR_HOME/bin

set -o vi

EOF_bashrc

	return 0
}

# If there's no mapr software installed, use imager script
# to do our initial setup.  Exit on failure
prepare_instance() {
	if [ ! -d ${MAPR_HOME} ] ; then
		if [ -z "${MAPR_IMAGER_SCRIPT}" ] ; then
			echo "ERROR: MapR software not found on image ..." >> $LOG
			echo "        and no imager script was provided.  Exiting !!!" >> $LOG
			exit 1
		fi
	
		echo "Executing imager script;" >> $LOG
		echo "    see /tmp/prepare-mapr-image.log for details" >> $LOG
		MAPR_IMAGER_FILE=/tmp/mapr_imager.sh
		curl -H "$md_header" $murl_attr/maprimagerscript > $MAPR_IMAGER_FILE
		chmod a+x $MAPR_IMAGER_FILE
		$MAPR_IMAGER_FILE
		return $?
	fi
	
	return 0
}


# Takes the packages defined by MAPR_PACKAGES and makes sure
# that those (and only those) are installed.
#
#	Input: MAPR_PACKAGES  (global)
#
install_mapr_packages() {
	if [ -z "${MAPR_PACKAGES:-}" ] ; then
		echo "No MapR software specified ... terminating script" >> $LOG
		return 1
	fi

	echo Installing MapR software components >> $LOG

	if which dpkg &> /dev/null ; then
#		MAPR_INSTALLED=`dpkg --list mapr-* | grep ^ii | awk '{print $2}'`
		MAPR_INSTALLED=`dpkg --get-selections mapr-* | awk '{print $1}'`
	else
		MAPR_INSTALLED=`rpm -q --all --qf "%{NAME}\n" | grep ^mapr `
	fi
	MAPR_REQUIRED=""
	for pkg in `echo ${MAPR_PACKAGES//,/ }`
	do
		MAPR_REQUIRED="$MAPR_REQUIRED mapr-${pkg#mapr-}"
	done

		# Be careful about removing -core or -internal packages
	MAPR_TO_REMOVE=""
	for pkg in $MAPR_INSTALLED
	do
		if [ ${pkg%-core} = $pkg  -a  ${pkg%-internal} = $pkg ] ; then
			echo $MAPR_REQUIRED | grep -q $pkg
			[ $? -ne 0 ] && MAPR_TO_REMOVE="$MAPR_TO_REMOVE $pkg"
		fi
	done

	MAPR_TO_INSTALL=""
	for pkg in $MAPR_REQUIRED
	do
		echo $MAPR_INSTALLED | grep -q $pkg
		[ $? -ne 0 ] && MAPR_TO_INSTALL="$MAPR_TO_INSTALL $pkg"
	done

	if [ -n "${MAPR_TO_REMOVE}" ] ; then
		c $UNINSTALL_CMD $MAPR_TO_REMOVE
	fi

	if [ -n "${MAPR_TO_INSTALL}" ] ; then
		c $INSTALL_CMD $MAPR_TO_INSTALL
	fi

	echo Configuring $MAPR_ENV_FILE  >> $LOG
	update-env-sh MAPR_HOME $MAPR_HOME
	update-env-sh JAVA_HOME $JAVA_HOME

	echo MapR software installation complete >> $LOG

	return 0
}

# Locate unused disks; save to MAPR_DISKS env variable.
#
find_mapr_disks() {
	disks=""
	for d in `fdisk -l 2>/dev/null | grep -e "^Disk .* bytes$" | awk '{print $2}' `
	do
		dev=${d%:}

		cfdisk -P s $dev &> /dev/null 
		[ $? -eq 0 ] && continue

		mount | grep -q -w -e $dev -e ${dev}1 -e ${dev}2
		[ $? -eq 0 ] && continue

		swapon -s | grep -q -w $dev
		[ $? -eq 0 ] && continue

		if which pvdisplay &> /dev/null; then
			pvdisplay $dev &> /dev/null
			[ $? -eq 0 ] && continue
		fi

		disks="$disks $dev"
	done

	MAPR_DISKS="$disks"
	export MAPR_DISKS
}

#
# Format disks (discovered or passed in as MAPR_DISKS) for MapR
#
provision_mapr_disks() {
	diskfile=/tmp/MapR.disks
	disktab=$MAPR_HOME/conf/disktab
	rm -f $diskfile
	[ -z "${MAPR_DISKS:-}" ] && find_mapr_disks
	if [ -n "$MAPR_DISKS" ] ; then
		for d in $MAPR_DISKS ; do echo $d ; done >> $diskfile
		if [ "${restore_only}" = "true" ] ; then
			if [ ! -f $disktab ] ; then
				echo $MAPR_HOME/server/disksetup -G $diskfile
				$MAPR_HOME/server/disksetup -G $diskfile > $disktab

					# disksetup does not set the proper permissions 
					# on the device files unless "-F" is used
				chmod g+rw $MAPR_DISKS
				chgrp $MAPR_GROUP $MAPR_DISKS
			fi
		else
			c $MAPR_HOME/server/disksetup -M -F $diskfile
		fi
	else
		echo "No unused disks found" >> $LOG
		if [ -n "$MAPR_DISKS_PREREQS" ] ; then
			for pkg in `echo ${MAPR_DISKS_PREREQS//,/ }`
			do
				echo $MAPR_PACKAGES | grep -q $pkg
				if [ $? -eq 0 ] ; then 
					echo "MapR package{s} $MAPR_DISKS_PREREQS installed" >> $LOG
					echo "Those packages require physical disks for MFS" >> $LOG
					echo "Exiting startup script" >> $LOG
					exit 1
				fi
			done
		fi
	fi
}

# Update MapR host identity files if necessary.
configure_host_identity() {
	if [ "${restore_only}" = "true" ] ; then
		if [ -n "${restore_hostid}" ] ; then
			echo $restore_hostid > $MAPR_HOME/hostid
			chmod 444 $MAPR_HOME/hostid
		fi
	else
		HOSTID=$($MAPR_HOME/server/mruuidgen)
		echo $HOSTID > $MAPR_HOME/hostid
		echo $HOSTID > $MAPR_HOME/conf/hostid.$$
		chmod 444 $MAPR_HOME/hostid
	fi

	HOSTNAME_FILE="$MAPR_HOME/hostname"
	if [ ! -f $HOSTNAME_FILE ]; then
		/bin/hostname --fqdn > $HOSTNAME_FILE
		chown $MAPR_USER:$MAPR_GROUP $HOSTNAME_FILE
		if [ $? -ne 0 ]; then
			rm -f $HOSTNAME_FILE
			echo "Cannot find valid hostname. Please check your DNS settings" >> $LOG
		fi
	fi

}


# Initializes MySQL database if necessary.
#
#	Input: MAPR_METRICS_SERVER  (global)
#			MAPR_METRICS_DB		(global)
#			MAPR_METRICS_DEFAULT	(global)
#			MAPR_PACKAGES		(global)
#
# NOTE: It is simpler to use the hostname for mysql connections
#	even on the host running the mysql instance (probably because 
#	of mysql's strange handling of "localhost" when validating
#	login privileges).

configure_mapr_metrics() {
	[ -z "${MAPR_METRICS_SERVER:-}" ] && return 0
	[ -z "${MAPR_METRICS_DB:-}" ] && return 0

	if which yum &> /dev/null ; then
		yum list soci-mysql > /dev/null 2> /dev/null
		if [ $? -ne 0 ] ; then 
			echo "Skipping metrics configuration; missing dependencies" >> $LOG
			return 0
		fi
	fi

	echo "Configuring task metrics connection" >> $LOG

	# If the metrics server is specified, make sure the
	# metrics package is installed on every job tracker and 
	# webserver system ; otherwise, we'll just skip this step
	#
	#	NOTE: while it is unlikely that the METRICS_SERVER will
	#	have been specified WITHOUT the metrics package selected,
	#	we'll check for that case as well at this point.
	if [ ! -f $MAPR_HOME/roles/metrics ] ; then
		installMetrics=0
		[ $MAPR_METRICS_SERVER == $THIS_HOST ] && installMetrics=1
		[ -f $MAPR_HOME/roles/jobtracker ] && installMetrics=1
		[ -f $MAPR_HOME/roles/webserver ] && installMetrics=1

		[ $installMetrics -eq 0 ] && return 0

		$INSTALL_CMD mapr-metrics

		if [ $? -ne 0 ] ; then
			echo " ... installation of mapr-metrics failed" >> $LOG
			return 1
		fi
	fi

		# Don't exit the installation if this re-configuration fails
	echo "$MAPR_HOME/server/configure.sh -R -d ${MAPR_METRICS_SERVER}:3306 -du $MAPR_USER -dp $MAPR_PASSWD -ds $MAPR_METRICS_DB" >> $LOG
	$MAPR_HOME/server/configure.sh -R -d ${MAPR_METRICS_SERVER}:3306 \
		-du $MAPR_USER -dp $MAPR_PASSWD -ds $MAPR_METRICS_DB
	echo "   configure.sh returned $?" >> $LOG

		# Additional configuration required on WebServer nodes for MapR 1.x
		# Need to specify the connection metrics in the hibernate CFG file
		# Version 2 and beyond handles that configuration in configure.sh
	if [ -f $MAPR_HOME/roles/webserver  -a  ${MAPR_VERSION%%.*} = "1" ] ; then
		HIBCFG=$MAPR_HOME/conf/hibernate.cfg.xml
			# TO BE DONE ... fix database properties 
	fi
}


# Simple script to do any config file customization prior to 
# program launch
configure_mapr_services() {
	echo "Updating configuration for MapR services" >> $LOG

	CLDB_CONF_FILE=${MAPR_HOME}/conf/cldb.conf
	MFS_CONF_FILE=${MAPR_HOME}/conf/mfs.conf
	WARDEN_CONF_FILE=${MAPR_HOME}/conf/warden.conf

# 	give MFS more memory -- generally not necessary for MapR 3.0 and later
#sed -i 's/service.command.mfs.heapsize.percent=.*$/service.command.mfs.heapsize.percent=35/' $MFS_CONF_FILE

#	give CLDB more threads 
# sed -i 's/cldb.numthreads=10/cldb.numthreads=40/' $CLDB_CONF_FILE

		# Disable central configuration (spinning up Java processes
		# every 5 minutes doesn't help; we'll run it on our own)
	if [ -w $WARDEN_CONF_FILE ] ; then
		sed -i 's/centralconfig.enabled=true/centralconfig.enabled=false/' \
			${WARDEN_CONF_FILE}
	fi

		# Bug 11604 ... need to clean-up startup scripts so that
		# the SysV rc routines handle them properly. 
	for f in `ls /etc/init.d/mapr-*` ; do
		mapr_service=`basename $f`
		sed -i "s/#Provides:[ 	]*MapR .*$/# Provides: $mapr_service/" $f
	done
}

# Simple script to add useful parameters to the 
# Hadoop *.xml configuration files.   This should be done
# as a separate Python or Perl script to better handle
# the xml format !!!
#
update_site_config() {
	echo "Updating site configuration files" >> $LOG

	HADOOP_CONF_DIR=${MAPR_HADOOP_DIR}/conf
	MAPRED_CONF_FILE=${HADOOP_CONF_DIR}/mapred-site.xml
	CORE_CONF_FILE=${HADOOP_CONF_DIR}/core-site.xml

		# core-site changes need to include namespace mappings
    sed -i '/^<\/configuration>/d' ${CORE_CONF_FILE}

	echo "
<property>
  <name>hbase.table.namespace.mappings</name>
  <value>*:/user/\${user.name}</value>
</property>" | sudo tee -a ${CORE_CONF_FILE}

	echo "" | sudo tee -a ${CORE_CONF_FILE}
	echo '</configuration>' | tee -a ${CORE_CONF_FILE}

}


#
#  Wait until DNS can find all the zookeeper nodes
#	TBD: put a timeout ont this ... it's not a good design to wait forever
#
function resolve_zknodes() {
	echo "WAITING FOR DNS RESOLUTION of zookeeper nodes {$zknodes}" >> $LOG
	zkready=0
	while [ $zkready -eq 0 ]
	do
		zkready=1
		echo testing DNS resolution for zknodes
		for i in ${zknodes//,/ }
		do
			[ -z "$(dig -t a +search +short $i)" ] && zkready=0
		done

		echo zkready is $zkready
		[ $zkready -eq 0 ] && sleep 5
	done
	echo "DNS has resolved all zknodes {$zknodes}" >> $LOG
	return 0
}


# Enable NFS mount point for cluster
#	localhost:/mapr for hosts running mapr-nfs service
#	$MAPR_NFS_SERVER:/mapr for other hosts
#
MAPR_FSMOUNT=/mapr
MAPR_FSTAB=$MAPR_HOME/conf/mapr_fstab
SYSTEM_FSTAB=/etc/fstab

configure_mapr_nfs() {
	if [ -f $MAPR_HOME/roles/nfs ] ; then
		MAPR_NFS_SERVER=localhost
		MAPR_NFS_OPTIONS="hard,intr,nolock"
	else
		MAPR_NFS_OPTIONS="hard,intr"
	fi

		# Bail out now if there's not NFS server (either local or remote)
	[ -z "${MAPR_NFS_SERVER:-}" ] && return 0

		# Performance tune for NFS client on fast networks
	SYSCTL_CONF=/etc/sysctl.conf
	echo "#"                >> $SYSCTL_CONF
	echo "# MapR NFS tunes" >> $SYSCTL_CONF
	echo "#"                >> $SYSCTL_CONF

	vmopts="vm.dirty_ratio=10"
	vmopts="$vmopts vm.dirty_background_ratio=4"
	for vmopt in $vmopts
	do
		echo $vmopt >> $SYSCTL_CONF
		sysctl -w $vmopt
	done

	sysctl -w sunrpc.tcp_slot_table_entries=128
	if [ -d /etc/modprobe.d ] ; then
		SUNRPC_CONF=/etc/modprobe.d/sunrpc.conf
		grep -q tcp_slot_table_entries $SUNRPC_CONF  2> /dev/null
		if [ $? -ne 0 ] ; then
			echo "options sunrpc tcp_slot_table_entries=128" >> $SUNRPC_CONF
		fi
	fi

		# For RedHat distros, we need to start up NFS services
	if which rpm &> /dev/null; then
		/etc/init.d/rpcbind restart
		/etc/init.d/nfslock restart
	fi

	echo "Mounting ${MAPR_NFS_SERVER}:/mapr to $MAPR_FSMOUNT" >> $LOG
	mkdir $MAPR_FSMOUNT

		# I need to be smarter here about the "restore_only" case
	if [ $MAPR_NFS_SERVER = "localhost" ] ; then
		echo "${MAPR_NFS_SERVER}:/mapr	$MAPR_FSMOUNT	$MAPR_NFS_OPTIONS" >> $MAPR_FSTAB

		maprcli node services -nfs restart -nodes `cat $MAPR_HOME/hostname`
	else
		echo "${MAPR_NFS_SERVER}:/mapr	$MAPR_FSMOUNT	nfs	$MAPR_NFS_OPTIONS	0	0" >> $SYSTEM_FSTAB
		mount $MAPR_FSMOUNT
	fi
}

#
# Isolate the creation of the metrics database itself until
# LATE in the installation process, so that we can use the
# cluster file system itself if we'd like.  Default to 
# using that resource, and fall back to local storage if
# the creation of the volume fails.
#
#	CAREFUL : this routine uses the MAPR_FSMOUNT variable defined just
#	above ... so don't rearrange this code without moving that as well
#
create_metrics_db() {
	[ -z "${MAPR_METRICS_SERVER:-}"  -o  -z "$THIS_HOST" ] && return
	[ $MAPR_METRICS_SERVER != $THIS_HOST ] && return

	echo "Creating MapR metrics database" >> $LOG

		# Install MySQL, update MySQL config and restart the server
	MYSQL_OK=1
	if  which dpkg &> /dev/null ; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get install -y mysql-server mysql-client

		MYCNF=/etc/mysql/my.cnf
		sed -e "s/^bind-address.* 127.0.0.1$/bind-address = 0.0.0.0/g" \
			-i".localhost" $MYCNF 

		update-rc.d -f mysql enable
		service mysql stop
		MYSQL_OK=$?
	elif which rpm &> /dev/null  ; then 
		yum install -y mysql-server mysql

		MYCNF=/etc/my.cnf
		sed -e "s/^bind-address.* 127.0.0.1$/bind-address = 0.0.0.0/g" \
			-i".localhost" $MYCNF 

		chkconfig mysqld on
		service mysqld stop
		MYSQL_OK=$?
	fi

	if [ $MYSQL_OK -ne 0 ] ; then
		echo "Failed to install/configure MySQL" >> $LOG
		echo "Unable to create MapR metrics database" >> $LOG
		return 1
	fi

	echo "Initializing metrics database ($MAPR_METRICS_DB)" >> $LOG

		# If we have licensed NFS connectivity to the cluster, then 
		# we can create a MapRFS volume for the database and point there.
		# If the NFS mount point isn't visible, just leave the 
		# data directory as is and warn the user.
	useMFS=0
	maprcli license apps | grep -q -w "NFS" 
	if [ $? -eq 0 ] ; then
		[ -f $MAPR_HOME/roles/nfs ] && useMFS=1
		[ -n "${MAPR_NFS_SERVER}" ] && useMFS=1
	fi

		# SELINUX MUST be disabled in order for us to move the
		# MySQL data dir out from /var/lib/mysql.  This should
		# be established earlier in the system setup
		# Given that MySQL CANNOT use MFS if it is enabled, we default
		# to NOT using MFS unless we're SURE SELINUX is disabled.
	[ -r /selinux/enforce ] && seState=`cat /selinux/enforce`
	[ -f /etc/selinux/config  -a  ${seState:-1} -eq 1 ] && useMFS=0

	if [ $useMFS -eq 1 ] ; then
		MYSQL_DATA_DIR=/mysql

		maprcli volume create -name mapr.mysql -user mysql:fc \
		  -path $MYSQL_DATA_DIR -createparent true 
		maprcli acl edit -type volume -name mapr.mysql -user mysql:fc
		if [ $? -eq 0 ] ; then
				# Now we'll access the DATA_DIR via an NFS mount
			MYSQL_DATA_DIR=${MAPR_FSMOUNT}/${cluster}${MYSQL_DATA_DIR}

				# Short wait for NFS client to see newly created volume
			sleep 5
			find `dirname $MYSQL_DATA_DIR` &> /dev/null
			if [ -d ${MYSQL_DATA_DIR} ] ; then
				chown --reference=/var/lib/mysql $MYSQL_DATA_DIR

			    sedArg="`echo "$MYSQL_DATA_DIR" | sed -e 's/\//\\\\\//g'`"
				sed -e "s/^datadir[ 	=].*$/datadir = ${sedArg}/g" \
					-i".localdata" $MYCNF 

                    # Default MySql 5.5 has innodb, but doesn't
					# specify a data file.  We'll do it here
					# if we see InnoDB in the MYCNF file
				sed -e "/^#.*InnoDB$/a\
innodb_data_file_path=ibdata1:10M:autoextend:max:1024M" $MYCNF

					# On Ubuntu, AppArmor gets in the way of
					# mysqld writing to the NFS directory; We'll 
					# unload the configuration here so we can safely
					# update the aliases file to enable the proper
					# access.  The profile will be reloaded when mysql 
					# is launched below
				if [ -f /etc/apparmor.d/usr.sbin.mysqld ] ; then
					echo "alias /var/lib/mysql/ -> ${MYSQL_DATA_DIR}/," >> \
						/etc/apparmor.d/tunables/alias

					apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld
				fi

					# Remember to initialize the new data directory !!!
					# If this fails, go back to the default datadir
				mysql_install_db --user=mysql
				if [ $? -ne 0 ] ; then
					echo "Failed to initialize MapRFS datadir {$MYSQL_DATA_DIR}" >> $LOG
					echo "Restoring localdata configuration" >> $LOG
					cp -p ${MYCNF}.localdata ${MYCNF}
				fi
			fi
		fi
	fi

		# Startup MySQL so the rest of this stuff will work
	[ -x /etc/init.d/mysql ]   &&  service mysql  start
	[ -x /etc/init.d/mysqld ]  &&  service mysqld start

		# At this point, we can customize the MySQL installation 
		# as needed.   For now, we'll just enable multiple connections
		# and create the database instance we need.
		#	WARNING: don't mess with the single quotes !!!
	mysql << metrics_EOF

create user '$MAPR_USER' identified by '$MAPR_PASSWD' ;
create user '$MAPR_USER'@'localhost' identified by '$MAPR_PASSWD' ;
grant all on $MAPR_METRICS_DB.* to '$MAPR_USER'@'%' ;
grant all on $MAPR_METRICS_DB.* to '$MAPR_USER'@'localhost' ;
quit

metrics_EOF

		# Update setup.sql in place, since we've picked
		# a new metrics db name.
	if [ !  $MAPR_METRICS_DB = $MAPR_METRICS_DEFAULT ] ; then
		sed -e "s/ $MAPR_METRICS_DEFAULT/ $MAPR_METRICS_DB/g" \
			-i".default" $MAPR_HOME/bin/setup.sql 
	fi
	mysql -e "source $MAPR_HOME/bin/setup.sql"

		# Lastly, we should set the root password to lock down MySQL
#	/usr/bin/mysqladmin -u root password "$MAPR_PASSWD"
}

function disable_mapr_services() 
{
	echo Disabling MapR services >> $LOG

	if which update-rc.d &> /dev/null; then
		[ -f $MAPR_HOME/conf/warden.conf ] && \
			c update-rc.d -f mapr-warden disable
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c update-rc.d -f mapr-zookeeper disable
	elif which chkconfig &> /dev/null; then
		[ -f $MAPR_HOME/conf/warden.conf ] && \
			c chkconfig mapr-warden off
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c chkconfig mapr-zookeeper off
	fi
}


# For now, we won't error-out if the enabling auto-start of the
# mapr-services fails.  Debian seems to have problems with update-rc.d.
function enable_mapr_services() 
{
	echo Enabling MapR services >> $LOG

	if which update-rc.d &> /dev/null; then
		[ -f $MAPR_HOME/conf/warden.conf ] && \
			c update-rc.d -f mapr-warden enable
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c update-rc.d -f mapr-zookeeper enable
	elif which chkconfig &> /dev/null; then
		[ -f $MAPR_HOME/conf/warden.conf ] && \
			c chkconfig mapr-warden on
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c chkconfig mapr-zookeeper on
	fi
}

function wait_for_user_ticket()
{
	grep -q "secure=true" $MAPR_HOME/conf/mapr-clusters.conf
	if [ $? -ne 0 ] ; then
		return
	fi

	USERTICKET=${MAPR_HOME}/conf/mapruserticket

	TICKET_WAIT=300

	SWAIT=$TICKET_WAIT
	STIME=3
	test -r $USERTICKET
	while [ $? -ne 0  -a  $SWAIT -gt 0 ] ; do
		sleep $STIME
		SWAIT=$[SWAIT - $STIME]
		test -r $USERTICKET
	done

	if [ -r $USERTICKET ] ; then
		MAPR_TICKETFILE_LOCATION=${USERTICKET}
		export MAPR_TICKETFILE_LOCATION
	fi
}

function start_mapr_services() 
{
	echo "Starting MapR services" >> $LOG

	if [ -f $MAPR_HOME/roles/zookeeper ] ; then
		if [ "${restore_only}" = "true" ] ; then
			echo "Postponing zookeeper startup until zkdata properly restored" >> $LOG
		else
			c service mapr-zookeeper start
		fi
	fi
	if [ -f $MAPR_HOME/conf/warden.conf ] ; then
		c service mapr-warden start
	fi

		# This is as logical a place as any to wait for HDFS to
		# come on line.  If security is enabled, we need to wait
		# a few minutes for the user ticket to be generated FIRST
	grep -q "secure=true" $MAPR_HOME/conf/mapr-clusters.conf
	if [ $? -eq 0 ] ; then
		wait_for_user_ticket	
	fi

		# We REALLY need java_home set here
	[ -f /etc/profile.d/javahome.sh ]  && . /etc/profile.d/javahome.sh

	HDFS_ONLINE=0
	HDFS_MAX_WAIT=600
	echo "Waiting for hadoop file system to come on line" | tee -a $LOG
	i=0
	while [ $i -lt $HDFS_MAX_WAIT ] 
	do
		hadoop fs -stat /  &> /dev/null
		if [ $? -eq 0 ] ; then
			curTime=`date`
			echo " ... success at $curTime !!!" | tee -a $LOG
			HDFS_ONLINE=1
			i=9999
			break
		else
			echo " ... timeout in $[HDFS_MAX_WAIT - $i] seconds ($THIS_HOST)"
		fi

		sleep 3
		i=$[i+3]
	done

	if [ ${HDFS_ONLINE} -eq 0 ] ; then
		echo "ERROR: MapR File Services did not come on-line" >> $LOG
		return 1
	fi

	return 0
}

# Look to the cluster for shared ssh keys.  This function depends
# on the cluster being up and happy.  Don't worry about errors
# here, this is just a helper function
function retrieve_ssh_keys() 
{
	echo "Retrieving ssh keys for other cluster nodes" >> $LOG

	MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
	clusterKeyDir=/cluster-info/keys

	hadoop fs -stat ${clusterKeyDir}
	[ $? -ne 0 ] && return 0

	kdir=$clusterKeyDir
		
		# Copy root keys FIRST ... since the MapR user keys are 
		# more important (and we want to give more time)
	akFile=/root/.ssh/authorized_keys
	for kf in `hadoop fs -ls ${kdir} | grep ${kdir} | grep _root | awk '{print $NF}' | sed "s_${kdir}/__g"`
	do
		echo "  found $kf"
		if [ ! -f /root/.ssh/$kf ] ; then
			hadoop fs -get ${kdir}/${kf} /root/.ssh/$kf
			cat /root/.ssh/$kf >> ${akFile}
		fi
	done

	akFile=${MAPR_USER_DIR}/.ssh/authorized_keys
	for kf in `hadoop fs -ls ${kdir} | grep ${kdir} | grep _${MAPR_USER} | awk '{print $NF}' | sed "s_${kdir}/__g"`
	do
		echo "  found $kf"
		if [ ! -f ${MAPR_USER_DIR}/.ssh/$kf ] ; then
			hadoop fs -get ${kdir}/${kf} ${MAPR_USER_DIR}/.ssh/$kf
			cat ${MAPR_USER_DIR}/.ssh/$kf >> ${akFile}
			chown --reference=${MAPR_USER_DIR} \
				${MAPR_USER_DIR}/.ssh/$kf ${akFile}
		fi
	done
}

# Returns 1 if volume comes on line within 5 minutes
# Need this functionality to ensure proper addition of our new volumes.
#
wait_for_mapr_volume() {
	VOL=$1
	VOL_ONLINE=0
	[ -z "${VOL}" ] && return $VOL_ONLINE

	echo "Waiting for $VOL volume to come on line" >> $LOG
	i=0
	while [ $i -lt 300 ] 
	do
		maprcli volume info -name $VOL &> /dev/null
		if [ $? -eq 0 ] ; then
			echo " ... success !!!" >> $LOG
			VOL_ONLINE=1
			i=9999
			break
		fi

		sleep 3
		i=$[i+3]
	done

	return $VOL_ONLINE
}

# Enable FullControl for MAPR_USER and install a license (if we have one)
#
finalize_mapr_cluster() {
	[ "${restore_only}" = "true" ] && return 

#	echo "Entering finalize_mapr_cluster" >> $LOG

	which maprcli  &> /dev/null
	if [ $? -ne 0 ] ; then
		echo "maprcli command not found" >> $LOG
		echo "This is typical on a client-only install" >> $LOG
		return 0
	fi
																
		# Run extra steps on CLDB nodes 
		#	(since they are needed only once per cluster)
	[ ! -f $MAPR_HOME/roles/cldb ] && return 0

		# Allow MAPR_USER to manage cluster
	c maprcli acl edit -type cluster -user ${MAPR_USER}:fc

	if [ ${#MAPR_LICENSE} -gt 0 ] ; then
		MAPR_LICENSE_FILE=/tmp/mapr.license
		echo $MAPR_LICENSE > $MAPR_LICENSE_FILE

		license_installed=0
		for lic in `maprcli license list | grep hash: | cut -d" " -f 2 | tr -d "\""`
		do
			grep -q $lic $MAPR_LICENSE_FILE
			[ $? -eq 0 ] && license_installed=1
		done

		if [ $license_installed -eq 0 ] ; then 
			echo "maprcli license add -license $MAPR_LICENSE_FILE -is_file true" >> $LOG
			maprcli license add -license $MAPR_LICENSE_FILE -is_file true
				# As of now, maprcli does not print an error if
				# the license already exists ... so there won't be any
				# strange messages in $LOG
		fi
	else
		echo "No license provided ... please install one at your earliest convenience" >> $LOG
	fi

		#
		# Enable centralized logging
		#	need to wait for mapr.logs to exist before we can
		#	create our entry point
		#
		# Then create a home directory for the user (since system 
		# volumes are now alive)
		#	
	wait_for_mapr_volume mapr.var
	VAR_ONLINE=$?

	if [ ${VAR_ONLINE} -eq 0 ] ; then
		echo "WARNING: mapr.var volume did not come on-line" >> $LOG
	else
		LOGS_VOL="mapr.logs"
		echo "Creating volume for centralized logs" >> $LOG
		maprcli volume create -name $LOGS_VOL \
			-path /var/mapr/logs -createparent true 

			# If the volume exists (either because we created it
			# or another node in the cluster already did it for us,
			# enable access and then execute the link-logs for this node
		maprcli volume info -name $LOGS_VOL  &> /dev/null
		if [ $? -eq 0 ] ; then
			maprcli acl edit -type volume -name $LOGS_VOL -user ${MAPR_USER}:fc
			maprcli job linklogs -jobid "job_*" -todir /var/mapr/logs
		fi
	fi

	wait_for_mapr_volume users
	USERS_ONLINE=$?

	if [ ${USERS_ONLINE} -eq 0 ] ; then
		echo "WARNING: user volume did not come on-line" >> $LOG
	else
		HOME_VOL=${MAPR_USER}_home

		maprcli volume info -name $HOME_VOL &> /dev/null
		if [ $? -ne 0 ] ; then
			echo "Creating home volume for ${MAPR_USER}" >> $LOG
			su $MAPR_USER -c "maprcli volume create -name ${HOME_VOL} -path /user/${MAPR_USER} -replicationtype low_latency"
		fi
	fi
}


function main()
{
	echo "Instance initialization started at "`date` >> $LOG

	prepare_instance
	if [ $? -ne 0 ] ; then
		echo "incomplete system initialization" >> $LOG
		echo "$0 script exiting with error at "`date` >> $LOG
		exit 1
	fi

	#
	# Install the software first ... that will give other nodes
	# the time to come up.
	#
	install_mapr_packages
	[ $? -ne 0 ] && return $?

	#
	#  If no MapR cluster definition is given, exit
	#
	if [ -z "${cluster}" -o  -z "${zknodes}"  -o  -z "${cldbnodes}" ] ; then
		echo "Insufficient specification for MapR cluster ... terminating script" >> $LOG
		exit 1
	fi

	add_mapr_user

	configure_host_identity 

		# Prepare to configure the node, supporting version-specific options
	major_ver=${MAPR_VERSION%%.*}
	ver=${MAPR_VERSION#*.}
	minor_ver=${ver%%.*}
	MVER=${major_ver}${minor_ver}   # Simpler representation ... 3.1.0 => 31

	[ -n "${THIS_IMAGE}" ] && VMARG="--isvm"
	if [ ${MVER} -ge 30 ] ; then
		if [ "${MAPR_VERSION}" != "3.0.0-GA" ] ; then
			echo $MAPR_PACKAGES | grep -q hbase
			[ $? -eq 0 ] && M7ARG="-M7"
			if [ -z "${M7ARG:-}"  -a  ${#MAPR_LICENSE} -gt 0 ] ; then
				echo ${MAPR_LICENSE} | grep -q MAPR_TABLES
				[ $? -eq 0 ] && M7ARG="-M7"
			fi
		fi
	fi

	if [ $MVER -ge 31 ] ; then
		if [ "${MAPR_SECURITY:-}" = "master" ] ; then
			SECARG="-secure -genkeys"
		elif [ "${MAPR_SECURITY:-}" = "enabled" ] ; then
			SECARG="-secure"

				# If security is "enabled", but no SEC_MASTER, 
				# override setting here
			if [ -z "${MAPR_SEC_MASTER}" ] ; then
				SECARG="-unsecure"
			elif [ "${MAPR_SEC_MASTER%%.*}" = "$THIS_HOST" ] ; then
				SECARG="-secure -genkeys"
			else
				retrieve_mapr_security_credentials
				[ $? -ne 0 ] && SECARG="-unsecure"
					# TBD : should handle this error better
			fi
		else
			SECARG="-unsecure"
		fi
		AUTOSTARTARG="-f -no-autostart -on-prompt-cont y"
		verbose_flag="-v"
	fi

		# Waiting for the nodes at this point SHOULD be unnecessary,
		# since we had to have the node alive to re-spawn this part
		# of the script.  So we can just do the configuration
	c $MAPR_HOME/server/configure.sh \
		$verbose_flag \
		-N $cluster -C $cldbnodes -Z $zknodes \
	    -u $MAPR_USER -g $MAPR_GROUP \
		$M7ARG $AUTOSTARTARG $SECARG $VMARG

	configure_mapr_metrics
	configure_mapr_services
	update_site_config

	provision_mapr_disks

		# Most of the time in virtual environments we DO NOT 
		# want to auto-start ... so we'll control that here.
	if [ -z "${THIS_IMAGE}" ] ; then
		enable_mapr_services
	else
		disable_mapr_services
	fi

	resolve_zknodes
	if [ $? -eq 0 ] ; then
		start_mapr_services
		[ $? -ne 0 ] && return $?

		finalize_mapr_cluster

		configure_mapr_nfs

		create_metrics_db
	fi

	echo "Instance initialization completed at "`date` >> $LOG
	echo INSTANCE READY >> $LOG
	return 0
}


main
exitCode=$?

# Save of the install log to ~${MAPR_USER}; some cloud images
# use AMI's that automatically clear /tmp with every reboot
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
if [ -n "${MAPR_USER_DIR}"  -a  -d ${MAPR_USER_DIR} ] ; then
		cp $LOG $MAPR_USER_DIR
		chmod a-w ${MAPR_USER_DIR}/`basename $LOG`
		chown ${MAPR_USER}:`id -gn ${MAPR_USER}` \
			${MAPR_USER_DIR}/`basename $LOG`
fi

exit $exitCode
