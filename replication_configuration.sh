#!/bin/bash
# Script to configure master / replica replication
# Kester Riley
# April 2018

# Inputs: "remote master host", "remote master user","remote master password","local master host", "local master user","local master password"


if [[ ! -z "$1" ]]; then
  lv_remote_master_host=$1
else
  echo "lv_remote_master_host is not set, check configuration."
  exit
fi

if [[ ! -z "$2" ]]; then
  lv_remote_master_user=$2
else
  echo "lv_remote_master_user is not set, check configuration."
  exit
fi

if [[ ! -z "$3" ]]; then
  lv_remote_master_password=$3
else
  echo "lv_remote_master_host is not set, check configuration."
  exit
fi

if [[ ! -z "$4" ]]; then
  lv_local_master_host=$4
else
  echo "lv_local_master_host is not set, check configuration."
  exit
fi

if [[ ! -z "$5" ]]; then
  lv_local_master_user=$5
else
  echo "lv_local_master_user is not set, check configuration."
  exit
fi

if [[ ! -z "$6" ]]; then
  lv_local_master_password=$6
else
  echo "lv_local_master_password is not set, check configuration."
  exit
fi

#Ensuring file is blank
echo > /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in

#Check to see if there is a gtid_slave_pos

lv_local_global_id=`mariadb -u$lv_local_master_user -p$lv_local_master_password -h$lv_local_master_host -bse "select @@gtid_slave_pos;"`

if [[ ! -n "$lv_local_global_id" ]]; then
  echo "There is no local Global Slave position available"
  echo "Fetching masters"
  lv_remote_global_id=`mariadb -u$lv_remote_master_user -p$lv_remote_master_password -h$lv_remote_master_host -bse "select @@gtid_slave_pos;"`
  if [[ ! -n "$lv_remote_global_id" ]]; then
    echo "No remote gtid_slave_pos EXITING"
    exit
  else
    echo "Setting gtid to $lv_remote_global_id"
    echo "STOP ALL SLAVES; SET GLOBAL gtid_slave_pos = '$lv_remote_global_id';" > /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in
  fi
else
  echo "There is a local Global Slave position available"
fi


echo "CHANGE MASTER '${lv_remote_master_host%%.*}' TO master_use_gtid = slave_pos, MASTER_HOST='$lv_remote_master_host', MASTER_USER='$lv_remote_master_user', MASTER_PASSWORD='$lv_remote_master_password', MASTER_CONNECT_RETRY=10; START ALL SLAVES;" >> /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in

if [[ -f /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in ]]; then

  echo "Initializing replication from clone position"
  mariadb -u$lv_local_master_user -p$lv_local_master_password -h$lv_local_master_host < /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in || exit 1
  # In case of container restart, attempt this at-most-once.
  mv /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.orig

fi
