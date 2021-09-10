#!/bin/bash

set -e

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-mysql}:x:$(id -u):0:${USER_NAME:-mysql} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

echo "===> Starting Application"

mkdir -pv /var/lib/mysql

function err_report () {
	echo "start.sh: Trapped error on line $1"
	exit
}
trap 'err_report $LINENO' ERR


function shutdown () {
	echo "Received TERM|INT signal."
	if [[ -f /var/lib/mysql/`hostname`.pid ]] && [[ -n $SYSTEM_PASSWORD ]]; then
		echo "Shutting down..."
    mysqladmin -usystem -h127.0.0.1 -p$SYSTEM_PASSWORD --wait-for-all-slaves shutdown
    while [  -f /var/lib/mysql/`hostname`.pid ]
    do
       sleep 2
       echo "Sleeping to allow shutdown to complete..."
    done
    echo "Process shutdown"
	else
		exit
	fi
}
trap shutdown TERM INT

# Set 'TRACE=y' environment variable to see detailed output for debugging
if [ "$TRACE" = "y" ]; then
	set -x
fi

function startProcess () {
  # start processes
  set +e -m

  # Allow external processes to write to docker logs (wsrep_notify_cmd)
  # Place it in a directory that is not writeable by mysql to prevent SST script from deleting it
  fifo=/tmp/mysql-console/fifo
  rm -rf $(dirname $fifo) \
    && mkdir -p $(dirname $fifo) \
    && chmod 755 $(dirname $fifo) \
    && mkfifo $fifo \
    && chmod o+rw $fifo \
    && echo "Tailing $fifo..." \
    && tail -f $fifo &
  tail_pid=$!
}

function create_db_users () {
  echo "Generating bootstrap script..."

  if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
    MARIADB_ROOT_PASSWORD=$(head -c 32 /dev/urandom | base64 | head -c 32)
    echo "MARIADB_ROOT_PASSWORD=$MARIADB_ROOT_PASSWORD"
  fi
  if [ -z "$MARIADB_ROOT_HOST" ]; then
    MARIADB_ROOT_HOST='127.0.0.1'
  fi

  >/tmp/bootstrap.sql

  # Create 'root' user
  cat >> /tmp/bootstrap.sql <<EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'${MARIADB_ROOT_HOST}' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD' WITH GRANT OPTION;
EOF
  if [ "$MARIADB_ROOT_SOCKET_AUTH" != "0" ]; then
    cat >> /tmp/bootstrap.sql <<EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED VIA unix_socket WITH GRANT OPTION;
EOF
  else
    cat >> /tmp/bootstrap.sql <<EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED BY '$MARIADB_ROOT_PASSWORD' WITH GRANT OPTION;
EOF
  fi

  # Create a 'maxscale' and 'system' user for healthchecks and shutdown signal
  cat >> /tmp/bootstrap.sql <<EOF
CREATE USER IF NOT EXISTS '$MAXSCALE_USER'@'%' IDENTIFIED BY '$MAXSCALE_USER_PASSWORD';
GRANT SELECT ON mysql.user TO '$MAXSCALE_USER'@'%';
GRANT SELECT ON mysql.db TO '$MAXSCALE_USER'@'%';
GRANT SELECT ON mysql.tables_priv TO '$MAXSCALE_USER'@'%';
GRANT SELECT ON mysql.columns_priv TO '$MAXSCALE_USER'@'%';
GRANT SELECT ON mysql.proxies_priv TO '$MAXSCALE_USER'@'%';
GRANT SELECT ON mysql.roles_mapping TO '$MAXSCALE_USER'@'%';
GRANT SHOW DATABASES ON *.* TO '$MAXSCALE_USER'@'%';
GRANT REPLICATION CLIENT, REPLICATION SLAVE, SUPER, RELOAD on *.* to '$MAXSCALE_USER'@'%';

CREATE USER IF NOT EXISTS '$MAXSCALE_MONITOR_USER'@'%' IDENTIFIED BY '$MAXSCALE_MONITOR_USER_PASSWORD';
GRANT SUPER, REPLICATION CLIENT, RELOAD, PROCESS, SHOW DATABASES, EVENT  on *.* to '$MAXSCALE_MONITOR_USER'@'%';

CREATE USER IF NOT EXISTS 'system'@'127.0.0.1' IDENTIFIED BY '$SYSTEM_PASSWORD';
GRANT PROCESS,SHUTDOWN ON *.* TO 'system'@'127.0.0.1';

CREATE USER IF NOT EXISTS '$MARIADB_USER'@'%' IDENTIFIED BY '$MARIADB_USER_PASSWORD' ;
GRANT ALL ON *.* TO '$MARIADB_USER'@'%' ;

CREATE USER IF NOT EXISTS '$REPLICATION_USER'@'%' IDENTIFIED BY '$REPLICATION_USER_PASSWORD' ;
GRANT REPLICATION SLAVE ON *.* TO '$REPLICATION_USER'@'%' ;
EOF

  # Create mariabackup user if needed
  if [[ $SST_METHOD =~ ^(mariabackup) ]] ; then
    cat >>/tmp/bootstrap.sql <<EOF
CREATE USER IF NOT EXISTS '$MARIABACKUP_USER'@'localhost';
GRANT PROCESS,RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO '$MARIABACKUP_USER'@'localhost';
EOF
    if [[ -n $MARIABACKUP_USER_PASSWORD ]]; then
      cat >>/tmp/bootstrap.sql <<EOF
SET PASSWORD FOR '$MARIABACKUP_USER'@'localhost' = PASSWORD('$MARIABACKUP_USER_PASSWORD');
EOF
    fi
  fi

  # Create user's database and user
  if [ "$MARIADB_DATABASE" ]; then
    echo "CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE\` ;" >> /tmp/bootstrap.sql
  fi

  echo "FLUSH PRIVILEGES;" >> /tmp/bootstrap.sql

  # Add additional database initialization scripts
  for f in /docker-entrypoint-initdb.d/*; do
          case "$f" in
                  *.sh)     echo "$0: running $f"; . "$f" ;;
                  *.sql)    echo "$0: appending $f"; cat "$f" >> /tmp/bootstrap.sql ;;
                  *.sql.gz) echo "$0: appending $f"; gunzip -c "$f" >> /tmp/bootstrap.sql ;;
                  *)        echo "$0: ignoring $f" ;;
          esac
          echo
  done

  MARIADB_MODE_ARGS+=" --init-file=/tmp/bootstrap.sql"

}

function startBackupStream ()
{
  if [[ -n $BACKUPSTREAM ]]; then
     echo "Starting a backup stream on port 3305"
  ncat --listen --keep-open --send-only --max-conns=1 3305 -c "mariabackup -u$MARIADB_USER -p$MARIADB_USER_PASSWORD --backup --slave-info --stream=xbstream --host=127.0.0.1 --user=$MARIADB_USER --password=$MARIADB_USER_PASSWORD" &
  echo "Started ncat stream for passing backups"
  else
    echo "Not starting a backup stream"
  fi
}

function restorefrombackup () {

    if [[ -n $BACKUPTORESTORE ]]; then

        echo "System will attempt to restore from a backup file."

        if [[ -f $BACKUPTORESTORE ]]; then

            echo "Have found Backup to Restore From: $BACKUPTORESTORE "

            if [[ -d $BACKUPCLUSTERDIR/restore ]]; then
              rm -rf $BACKUPCLUSTERDIR/restore
            fi

            mkdir -p $BACKUPCLUSTERDIR/restore
            chmod 777 $BACKUPCLUSTERDIR/restore
            echo "Uncompressing archive $BACKUPTORESTORE"
            tar -zxf $BACKUPTORESTORE --directory $BACKUPCLUSTERDIR/restore
            echo "Archive extracted to $BACKUPCLUSTERDIR/restore"
            if [[ -d /var/lib/mysql/mysql ]]; then
              echo "Data Directory already exists, removing it"
              rm -rf /var/lib/mysql/*
            fi
            echo "Copying Back Archive"
            mariabackup --copy-back --force-non-empty-directories --target-dir $BACKUPCLUSTERDIR/restore --datadir /var/lib/mysql/
            echo "Archived Restored"
            echo "Changing file ownership"
            chown -R mysql:mysql /var/lib/mysql/
        else
          echo "Unable to find Backup to restore: $BACKUPTORESTORE "
        fi
    fi

}

function checkandclone () {

  restorefrombackup

  if [[ -d /var/lib/mysql/mysql ]]; then
    echo "This server already has a data directory, not cloning another server."
  elif [[ `hostname` =~ -([0-9]+)$ ]]; then

    ordinal=${BASH_REMATCH[1]}
    if [[ $ordinal -eq 0 ]]; then

      #Check the environment variable to see if it is not an empty string

      if [[ -n $CLONEFROMREMOTE ]]; then
        echo "Server has no data directory, and is a master server and it is set to clone"
        echo " ... from $CLONEFROMREMOTE"
        ncat --recv-only $CLONEFROMREMOTE 3305 | mbstream -x -C /var/lib/mysql
        mariabackup --prepare --target-dir=/var/lib/mysql
        echo $CLONEFROMREMOTE > /var/lib/mysql/serverClonedFromRemoteMaster
        echo "THIS SERVER WAS CLONED FROM A REMOTE LOCATION, YOU MUST CONFIGURE REPLICATION"
      else
        echo "Server is a master server and therefore not cloning"
        echo "Creating Master Server Users"
        create_db_users
      fi
    else
      if [[ -n $BACKUPSTREAM ]]; then

        echo "Server is not a master, and has no data directory, we are going to clone"
        echo "Cloning from $BACKUPSTREAM"
        ncat --recv-only $BACKUPSTREAM 3305 | mbstream -x -C /var/lib/mysql
        mariabackup --prepare --target-dir=/var/lib/mysql
        touch /var/lib/mysql/servercloned
      else
          echo "BACKUPSTREAM is not defined"
          exit
      fi
    fi
  fi

}

function waitforservice () {

  echo "Started MariaDB"
  echo "****************************"
  echo "Waiting for MariaDB to be ready (accepting connections)"
  until mariadb -u$MARIADB_USER -p$MARIADB_USER_PASSWORD -h 127.0.0.1 -e "SELECT 1"; do echo "... Service not yet available, sleeping"; sleep 5; done
  echo "MariaDB accepting connections"
  echo "****************************"

}

function setupreplication () {

  echo "Checking to see if replication needs configuring"

  if [[ -f /var/lib/mysql/xtrabackup_info ]]; then
    echo "USING SLAVE GTID POS"
    slavegtidpos=`cat /var/lib/mysql/xtrabackup_info | grep binlog_pos | awk -F "change" ' { print $2 }'`
    if [[ -n $slavegtidpos ]]; then

      if [[ -n $MASTERHOST ]]; then
        echo "** Setting replication type to: $REPL_TYPE **"

        echo "SET GLOBAL gtid_slave_pos = $slavegtidpos;" > /var/lib/mysql/change_master_to.sql.in
        echo "CHANGE MASTER '${MASTERHOST%%.*}' TO master_use_gtid = $REPL_TYPE, MASTER_HOST='$MASTERHOST', MASTER_USER='$REPLICATION_USER', MASTER_PASSWORD='$REPLICATION_USER_PASSWORD', MASTER_CONNECT_RETRY=10; START SLAVE '${MASTERHOST%%.*}';" >> /var/lib/mysql/change_master_to.sql.in
      else
        echo "MASTERHOST is not set, check configuration."
      fi
    else
      echo "SLAVE POS IS EMPTY"
    fi

    if [[ -f /var/lib/mysql/change_master_to.sql.in ]]; then

      echo "Initializing replication from clone position"
      mariadb -u$MARIADB_USER -p$MARIADB_USER_PASSWORD -h 127.0.0.1 < /var/lib/mysql/change_master_to.sql.in || exit 1
      # In case of container restart, attempt this at-most-once.
      mv /var/lib/mysql/change_master_to.sql.in /var/lib/mysql/change_master_to.sql.orig

    fi

  fi

}

function startReadinessHealthCheck () {
  # Port 8080 only reports healthy when ready to serve clients
  # Use this one for load balancer health checks
  echo "STARTING HEALTH CHECK ON PORT 8080"
  ncat --listen --keep-open --send-only 8080 -c "/usr/local/bin/galera-health.sh type=readiness  availWhenDonor=false availWhenReadOnly=false" &
  echo $! >>/var/run/galera-healthcheck-1.pid
}

function startLivenessHealthCheck () {
  # Port 8081 reports healthy as long as the server is synced or donor/desynced state
  # Use this one to help other nodes determine cluster state before launching server
  echo "STARTING LIVENESS HEALTH CHECK ON PORT 8081"
  ncat --listen --keep-open --send-only 8081 -c "/usr/local/bin/galera-health.sh type=liveness" &
  echo $! >>/var/run/galera-healthcheck-2.pid
}

function standalone_install () {

  checkandclone

	set +e -m
  mariadb_control.sh \
   	$MARIADB_MODE_ARGS \
		--wsrep-on=OFF \
		"$@" 2>&1 &
  mariadb_pid=$!

  waitforservice

  if [[ -f /var/lib/mysql/servercloned ]]; then

     echo "This server was cloned from another, configuring replica"
     REPL_TYPE=current_pos
     setupreplication
     mv /var/lib/mysql/servercloned /var/lib/mysql/servercloned.OLD
  fi

  startReadinessHealthCheck
  startLivenessHealthCheck
  startBackupStream

  echo "Waiting for MariaDB to exit"
  wait $mariadb_pid || true
	exit

}

function initiate_mariabackup () {
set +e -m
  if [[ -n $BACKUPCLUSTER ]]; then


    echo "Creating Backup Directory"
    lv_date_time=$(date +%Y%m%d_%H%M%S)
    mkdir -p $BACKUPCLUSTERDIR/$lv_date_time
    chmod 777 $BACKUPCLUSTERDIR/$lv_date_time

    echo "Backing up from $BACKUPCLUSTER to $BACKUPCLUSTERDIR/$lv_date_time"
    ncat --recv-only $BACKUPCLUSTER 3305 | mbstream -x -C $BACKUPCLUSTERDIR/$lv_date_time
    echo "Backup Streamed, now preparing"
    mariabackup --prepare --target-dir=$BACKUPCLUSTERDIR/$lv_date_time
    echo "MariaBackup completed"

    echo "Compressing Backup to save disk space"
    tar -czvf $BACKUPCLUSTERDIR/$lv_date_time.tar.gz $BACKUPCLUSTERDIR/$lv_date_time

    echo "Removing backup directory if compression worked"

    if [[ -f $BACKUPCLUSTERDIR/$lv_date_time.tar.gz ]]
    then
       rm -rf $BACKUPCLUSTERDIR/$lv_date_time
    fi

    echo "Listing Backup Directory"
    ls -lrth $BACKUPCLUSTERDIR/

    if [[ -n $BACKUPPURGEDAYS ]]; then
      echo "Checking for old backups older than $BACKUPPURGEDAYS days and removing"
      find $BACKUPCLUSTERDIR/*.tar.gz -type d -ctime +$BACKUPPURGEDAYS -exec rm -rf {} +
    fi

    echo "Goodbye"
    exit
  else
      echo "BACKUPCLUSTER is not defined"
      exit
  fi



}


case "$1" in
	sleep)
		echo "Sleeping forever..."
		trap - TERM INT
		sleep infinity
		exit
		;;
	no-galera)
		echo "Starting standalone instance"
		shift 1
    echo "-------------- STARTING MODE: No Galera ---------------------"
    standalone_install
		;;
  mariabackup)
  	echo "Starting a backup instance"
  	shift 1
    echo "-------------- STARTING MODE: mariabackup ---------------------"
    initiate_mariabackup
  	;;
	bash)
		shift 1
		trap - TERM INT
		exec /bin/bash "$@"
		;;
	seed|node)
		START_MODE=$1
		shift
                echo "-------------- STARTING MODE: $START_MODE ---------------------"
		;;
	*)
		echo "sleep|no-galera|bash|seed|node|mariabackup <othernode>,..."
		exit 1
esac

#
# Resolve node address
#
if [ -z "$NODE_ADDRESS" ]; then
	# Support Weave/Kontena
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /ethwe/{sub(/\/.*$/,"",$2); print $2}')
fi
if [ -z "$NODE_ADDRESS" ]; then
	# Support Docker Swarm Mode
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /eth0/{sub(/\/.*$/,"",$2); print $2}' | head -n 1)
elif [[ "$NODE_ADDRESS" =~ [a-zA-Z][a-zA-Z0-9:]+ ]]; then
	# Support interface - e.g. Docker Swarm Mode uses eth0
	NODE_ADDRESS=$(ip addr | awk "/inet/ && / $NODE_ADDRESS\$/{sub(/\\/.*$/,\"\",\$2); print \$2}" | head -n 1)
elif ! [[ "$NODE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	# Support grep pattern. E.g. ^10.0.1.*
	NODE_ADDRESS=$(getent hosts $(hostname) | awk '{print $1}' | grep -e "$NODE_ADDRESS")
fi
if ! [[ "$NODE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Could not determine NODE_ADDRESS: $NODE_ADDRESS"
	exit 1
fi
echo "...------======------... MariaDB Galera Start Script ...------======------..."
echo "Got NODE_ADDRESS=$NODE_ADDRESS"

# Allow for easily adding more startup scripts
export NODE_ADDRESS
if [ -f /usr/local/bin/mariadb_custom_startup.sh ]; then
	source /usr/local/bin/mariadb_custom_startup.sh "$@"
fi

MARIADB_MODE_ARGS=""

if [[ $SST_METHOD =~ ^(mariabackup) ]] ; then

  [ -z "$MARIABACKUP_USER_PASSWORD" ] && echo "WARNING: MARIABACKUP_USER_PASSWORD is empty"
  MARIADB_MODE_ARGS+=" --wsrep_sst_auth=$MARIABACKUP_USER:$MARIABACKUP_USER_PASSWORD"
fi

if [ -z "$SYSTEM_PASSWORD" ]; then
  if [ -n "$SYSTEM_PASSWORD" ]; then
     SYSTEM_PASSWORD=$(echo "$SYSTEM_PASSWORD" | sha256sum | awk '{print $1;}')
  else
     echo "SYSTEM_PASSWORD not set"
     exit 1
  fi
fi

CLUSTER_NAME=${CLUSTER_NAME:-cluster}
GCOMM_MINIMUM=${GCOMM_MINIMUM:-2}
GCOMM=""

# Hold startup until the flag file is deleted
if [[ -f /var/lib/mysql/hold-start ]]; then
	echo "Waiting for 'hold-start' flag file to be deleted..."
	while [[ -f /var/lib/mysql/hold-start ]]; do
		sleep 10
	done
fi

# Allow "node" to be "seed" if "new-cluster" file is present
if [[ $START_MODE = "node" ]] && [[ -f /var/lib/mysql/new-cluster ]]; then
  if [[ -f /var/lib/mysql/grastate.dat ]]; then
      echo "This server is already in a cluster, ignoring bootstrap" > /tmp/bootstrap.log
  else
    START_MODE=seed
  	shift # get rid of node argument
    echo "This server was bootstrapped as the new cluster" > /tmp/bootstrap.log
  fi
  rm -f /var/lib/mysql/new-cluster
fi

# Generate init file to create required users
if   ( [ "$START_MODE" = "node" ] && [ -f /var/lib/mysql/force-cluster-bootstrapping ] ) \
  || ( [ "$START_MODE" = "seed" ] && ! [ -f /var/lib/mysql/skip-cluster-bootstrapping ] )
then
  create_db_users
  rm -f /var/lib/mysql/force-cluster-bootstrapping
  touch /var/lib/mysql/skip-cluster-bootstrapping
fi

#
# Start modes:
#  - seed - Start a new cluster - run only once and use 'node' after cluster is started
#  - node - Join an existing cluster
#
case $START_MODE in
	seed)
    checkandclone
		MARIADB_MODE_ARGS+=" --wsrep-on=ON --wsrep-new-cluster --wsrep-sst-method=$SST_METHOD "
		echo "Starting seed node"
	;;
	node)
		ADDRS="$1"
		shift
		if [[ -z $ADDRS ]]; then
			echo "List of nodes addresses/hostnames required"
			exit 1
		fi
		MARIADB_MODE_ARGS+=" --wsrep-on=ON --wsrep-sst-method=$SST_METHOD"
		RESOLVE=0
		SLEEPS=0

		# Begin service discovery of other node addresses
		while true; do
			# Allow user to touch flag file during startup
			if [[ -f /var/lib/mysql/new-cluster ]]; then
				MARIADB_MODE_ARGS+=" --wsrep-new-cluster"
				echo "Found 'new-cluster' flag file. Starting new cluster."
				rm -f /var/lib/mysql/new-cluster
				break
			fi
			SEP=""
			GCOMM=""
			for ADDR in ${ADDRS//,/ }; do
				if [[ "$ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
					GCOMM+="$SEP$ADDR"
				else
					RESOLVE=1
					GCOMM+="$SEP$(getent hosts "$ADDR" | awk '{ print $1 }' | paste -sd ",")"
				fi
				if [ -n "$GCOMM" ]; then
					SEP=,
				fi
			done
			GCOMM=${GCOMM%%,}                        # strip trailing commas
			GCOMM=$(echo "$GCOMM" | sed 's/,\+/,/g') # strip duplicate commas

			# Allow user to bypass waiting for other IPs
			if [[ -f /var/lib/mysql/skip-gcomm-wait ]]; then
				break
			fi

			# It is possible that containers on other nodes aren't running yet and should be waited on
			# before trying to start. For example, this occurs when updated container images are being pulled
			# by `docker service update <service>` or on a full cluster power loss

			COUNT=$(echo "$GCOMM" | tr ',' "\n" | sort -u | grep -v -e "^$NODE_ADDRESS\$" -e '^$' | wc -l)
			if [ $RESOLVE -eq 1 ] && [ $COUNT -lt $(($GCOMM_MINIMUM - 1)) ]; then

				echo "Waiting for at least $GCOMM_MINIMUM IP addresses to resolve..."
				SLEEPS=$((SLEEPS + 1))
				sleep 3
			else
				break
			fi

			# After 90 seconds reduce GCOMM_MINIMUM
			if [ $SLEEPS -ge 30 ]; then
				SLEEPS=0
				GCOMM_MINIMUM=$((GCOMM_MINIMUM - 1))
				echo "Reducing GCOMM_MINIMUM to $GCOMM_MINIMUM"
			fi
		done
		# Pre-boot completed
		echo "Starting node, connecting to gcomm://$GCOMM"
	;;
esac

startProcess
startReadinessHealthCheck
startLivenessHealthCheck

echo "STARTED HEALTH CHECKS"

# Run automated upgrades
# Script runs in the background waiting for the service to become available
# If an upgrade is required this will run.

#run-upgrades.sh || true &

mariadb_control.sh \
$MARIADB_MODE_ARGS \
--wsrep_cluster_name=$CLUSTER_NAME \
--wsrep_cluster_address=gcomm://$GCOMM \
--wsrep_node_address=$NODE_ADDRESS:4567 \
"$@" 2>&1 &

mariadb_pid=$!

waitforservice
# See if a Backup Stream is required
if [[ -f /var/lib/mysql/serverClonedFromRemoteMaster ]]; then

   echo "This server was cloned from another, configuring replica"
   REPL_TYPE=slave_pos
   setupreplication
   mv /var/lib/mysql/serverClonedFromRemoteMaster /var/lib/mysql/serverClonedFromRemoteMaster.OLD
fi
startBackupStream

wait $! || true
RC=$?

echo "MariaDB exited with return code ($RC)"
test -f /var/lib/mysql/grastate.dat && cat /var/lib/mysql/grastate.dat
test -s /var/run/galera-healthcheck-1.pid && kill $(cat /var/run/galera-healthcheck-1.pid)
test -s /var/run/galera-healthcheck-2.pid && kill $(cat /var/run/galera-healthcheck-2.pid)

echo "Goodbye"
exit $RC
