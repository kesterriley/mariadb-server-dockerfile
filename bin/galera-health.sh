#!/bin/bash
# Kester Riley <kesterriley@hotmail.com>

# A Script to check the health of a Galera Cluster

# Example of usage:
#  ncat --listen --keep-open --send-only 8080 -c "/usr/local/bin/galera-health.sh type=readiness  availWhenDonor=false availWhenReadOnly=false" &


MARIADB_OPTS="-N -q -A --connect-timeout=10"
STATE_QUERY="SHOW GLOBAL STATUS WHERE VARIABLE_NAME='wsrep_local_state'"
READONLY_QUERY="SHOW GLOBAL VARIABLES WHERE variable_name='read_only'"
COMMENT_QUERY="SHOW GLOBAL STATUS WHERE VARIABLE_NAME='wsrep_local_state_comment'"
MARIADB_ROOT_HOST="127.0.0.1"
type=""

for ARGUMENT in "$@"
do

    KEY=$(echo $ARGUMENT | cut -f1 -d=)
    VALUE=$(echo $ARGUMENT | cut -f2 -d=)

    case "$KEY" in
            availWhenDonor)     availWhenDonor=${VALUE} ;;
            availWhenReadOnly)  availWhenReadOnly=${VALUE} ;;
            type)               type=${VALUE} ;;
            *)
    esac


done

[[ "$type" == "readiness" ]] && READINESS=1 || READINESS=0
[[ "$type" == "liveness" ]] && LIVENESS=1 || LIVENESS=0

server_unavailable()
{
  echo -en "HTTP/1.1 503 Service Unavailable\r\n"
  echo -en "Content-Type: text/plain\r\n"
  echo -en "Connection: close\r\n"
  echo -en "Content-Length: 31\r\n"
  echo -en "\r\n"
  echo -en "MariaDB Server Not Available.\r\n"
  sleep 0.1
  exit 1
}

server_synced()
{
  echo -en "HTTP/1.1 200 OK\r\n"
  echo -en "Content-Type: text/plain\r\n"
  echo -en "Connection: close\r\n"
  echo -en "Content-Length: 40\r\n"
  echo -en "\r\n"
  echo -en "MariaDB Galera Cluster Node is synced.\r\n"
  sleep 0.1
  exit 0
}

server_readonly()
{
  echo -en "HTTP/1.1 503 Service Unavailable\r\n"
  echo -en "Content-Type: text/plain\r\n"
  echo -en "Connection: close\r\n"
  echo -en "Content-Length: 43\r\n"
  echo -en "\r\n"
  echo -en "MariaDB Galera Cluster Node is read-only.\r\n"
  sleep 0.1
  exit 1
}


server_notsynced()
{
  echo -en "HTTP/1.1 503 Service Unavailable\r\n"
  echo -en "Content-Type: text/plain\r\n"
  echo -en "Connection: close\r\n"
  echo -en "Content-Length: 44\r\n"
  echo -en "\r\n"
  echo -en "MariaDB Galera Cluster Node is not synced.\r\n"
  sleep 0.1
  exit 1
}

server_notinitialized()
{
  echo -en "HTTP/1.1 503 Service Unavailable\r\n"
  echo -en "Content-Type: text/plain\r\n"
  echo -en "Connection: close\r\n"
  echo -en "Content-Length: 49\r\n"
  echo -en "\r\n"
  echo -en "MariaDB Galera Cluster Node is not initialized.\r\n"
  sleep 0.1
  exit 1
}

#Checking for status, possible values are:
# 1	Joining	Node is joining the cluster
# 2	Donor/Desynced	Node is the donor to the node joining the cluster
# 3	Joined	Node has joined the cluster
# 4	Synced	Node is synced with the cluster

status=$(mariadb $MARIADB_OPTS -h$MARIADB_ROOT_HOST -uroot -p$MARIADB_ROOT_PASSWORD -e "$STATE_QUERY;" 2>/dev/null | awk '{print $2;}')
[[ $? -ne 0 ]] && server_unavailable

if [ $READINESS -eq 1 ]
then
	# A node is ready when it reaches Synced or when it is a Donor if availWhenDonor = true
  if [[ "${status}" == "4" ]] || [[ "${status}" == "2" && ${availWhenDonor} == "true" ]]
  then

    if [[ ${availWhenReadOnly} == "true" ]]
    then
      readonly=$(mariadb $MYSQL_OPTS -h$MARIADB_ROOT_HOST -uroot -p$MARIADB_ROOT_PASSWORD -e "$READONLY_QUERY;" 2>/dev/null | awk '{print $2;}')
      [[ $? -ne 0 ]] && server_unavailable
      [[ "${readonly}" == "ON" ]] &&  server_readonly
    fi

		server_synced
  else
    server_notsynced
	fi
elif [ $LIVENESS -eq 1 ]
then
	# A node is alive if it's not in Initialized state

  # When the node is part of the Primary Component,
  # the typical return values are:
  # Joining
  # Waiting on SST
  # Joined,
  # Synced
  # Donor
  # If the node is part of a nonoperational component, the return value is Initialized.

	comment_status=$(mariadb $MARIADB_OPTS -h$MARIADB_ROOT_HOST -uroot -p$MARIADB_ROOT_PASSWORD -e "$COMMENT_QUERY;" 2>/dev/null | awk '{print $2;}')
  [[ $? -ne 0 ]] && server_unavailable
  [[ "${comment_status}" != "Initialized" ]] && server_synced || server_notinitialized

else
# if script is not running as a readiness or liveness check
    if [[ "${status}" == "4" ]] || [[ "${status}" == "2" && ${availWhenDonor} == "true" ]]
    then
        if [[ ${availWhenReadOnly} == "true" ]]
        then
          readonly=$(mariadb $MYSQL_OPTS -h$MARIADB_ROOT_HOST -uroot -p$MARIADB_ROOT_PASSWORD -e "$READONLY_QUERY;" 2>/dev/null | awk '{print $2;}')
          [[ $? -ne 0 ]] && server_unavailable
          [[ "${readonly}" == "ON" ]] &&  server_readonly
        fi
        server_synced
    else
      server_notsynced
    fi
fi
server_unavailable
