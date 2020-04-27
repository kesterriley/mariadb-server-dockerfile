#!/bin/bash
# Script to configure master / replica replication
# Kester Riley
# April 2018

# Inputs: "remote master host", "remote master user","remote master password","local master host", "local master user","local master password"

[[ ! -z "$1" ]] && lv_remote_master_host=$1 || echo "lv_remote_master_host is not set, check configuration."; exit
[[ ! -z "$1" ]] && lv_remote_master_user=$1 || echo "lv_remote_master_user is not set, check configuration."; exit
[[ ! -z "$1" ]] && lv_remote_master_password=$1 || echo "lv_remote_master_password is not set, check configuration."; exit
[[ ! -z "$1" ]] && lv_local_master_host=$1 || echo "lv_local_master_host is not set, check configuration."; exit
[[ ! -z "$1" ]] && lv_local_master_user=$1 || echo "lv_local_master_user is not set, check configuration."; exit
[[ ! -z "$1" ]] && lv_local_master_password=$1 || echo "lv_local_master_password is not set, check configuration."; exit

echo "STOP SLAVE '${lv_remote_master_host%%.*}'; SET GLOBAL gtid_slave_pos = $slavegtidpos;" > /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in
echo "CHANGE MASTER '${lv_remote_master_host%%.*}' TO master_use_gtid = slave_pos, MASTER_HOST='$lv_remote_master_host', MASTER_USER='$lv_remote_master_user', MASTER_PASSWORD='$lv_remote_master_password', MASTER_CONNECT_RETRY=10; START SLAVE '${lv_remote_master_host%%.*}';" >> /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in

if [[ -f /var/lib/mysql/change_master_to.sql.in ]]; then

  echo "Initializing replication from clone position"
  mariadb -u$lv_local_master_user -p$lv_local_master_password -h 127.0.0.1 < /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in || exit 1
  # In case of container restart, attempt this at-most-once.
  mv /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.in /var/lib/mysql/change_master_to_${lv_remote_master_host%%.*}.sql.orig

fi
