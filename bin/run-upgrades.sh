#!/bin/bash

while true; do
	if curl -sf -o /dev/null localhost:8080; then
		break
	fi
	echo "$0: waiting for server to become available..."
	sleep 10
done

version=$(mariadb -uroot -p$MARIADB_ROOT_PASSWORD -h127.0.0.1 -sNe "SELECT VERSION();")
if [[ -z $version ]]; then
	echo "$0: = Could not login as root to determine MySQL version and run upgrades! ="
	exit 1
fi

FLAG=/var/lib/mysql/run-upgrades.flag
old_version=
if [[ -f $FLAG ]]; then
	old_version=$(grep -v '#' $FLAG)
fi

if [[ -z $old_version ]]; then
	echo -e "# Created by $0 on $(date)\n# DO NOT DELETE THIS FILE\n$version" > $FLAG
fi

if [[ -n $old_version ]] && [[ $version != $old_version ]]; then
	echo -e "# Created by $0 on $(date)\n# DO NOT DELETE THIS FILE\n$version" > $FLAG
	echo "$0: Detected old version ($old_version -> $version)"
	echo "$0: Running mysql_upgrade..."
	mysql_upgrade -uroot -p$MARIADB_ROOT_PASSWORD -h127.0.0.1
fi
