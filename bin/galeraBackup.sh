#!/bin/bash
# Kester Riley <kesterriley@hotmail.com>

# A Backup Script for Galera Database, providing Full, Incremental and restore capabillities.

######################
# Set some Variables #
######################


DB_User=bkpuser
DB_Pass=NVNzfpjm8ej2Mcyh
DB_Sock=/var/lib/mysql/mysql.sock
DB_Conf=/etc/my.cnf.d/server.cnf
BackUpLocation=/data/backups
MySqlDataDir=/var/lib/mysql

GaleraBackup="--galera-info"
#GaleraBackup=""

SCRIPTNAME=`basename "$0"`

Back_Up_User_Settings="--user=$DB_User --password=$DB_Pass --socket=$DB_Sock" # --defaults-file=$DB_Conf
Back_Up_Settings="--rsync $Back_Up_User_Settings --ftwrl-wait-threshold=40 --ftwrl-wait-query-type=all --ftwrl-wait-timeout=180 --kill-long-queries-timeout=20 --kill-long-query-type=all $GaleraBackup"


######################################################################################
# Backup Technoligies
# https://mariadb.com/kb/en/library/mariadb-backup-overview/ -- mariabackup
#
# Backup to use
#
 backup_software=mariabackup
########################################################################################



function init()
{
    lv_output=""
    lv_output_return_code=""
    Red='\033[0;31m'          # Red
    Green='\033[0;32m'        # Green
    Yellow='\033[0;33m'       # Yellow
    White='\033[0;37m'        # White
    Blue='\033[0;34m'         # Blue
}

function OutPut()
{
	if [ "$1" = "FAIL" ]; then  lv_output=$lv_output"${Red}FAIL: ${White}"; elif [ "$1" = "WARN" ]; then lv_output=$lv_output"${Yellow}WARN: ${White}";  elif [ "$1" = "PASS" ]; then lv_output=$lv_output"${Green}PASS: ${White}"; elif [ "$1" = "INFO" ]; then lv_output=$lv_output"${Blue}INFO: ${White}"; fi
	lv_output=$lv_output"${2}\n"
}


function returnOutPut()
{
	clear
	printf "${lv_output}"
}


## Need to Purge old backups, but not beyond previous full

# find older backups and kill them
#echo "removing backups older than 3 days"
#find /data/backups -type d -ctime +3 -exec rm -rvf '{}' \;


Do_Full_Backup() {

	OutPut "INFO" "Full Backup Started"
        if [ ! -d $BackUpLocation ]
        then
		OutPut "INFO" "... making backup folder"
	        mkdir -p $BackUpLocation/FULL
        else
		OutPut "INFO" "... removing old backups"
		rm -rf $BackUpLocation/*
	fi
        OutPut "INFO" "... backup started"
        $backup_software --backup $Back_Up_Settings --target-dir $BackUpLocation/FULL
	retval="$?"
	if [ $retval -ne 0 ]
	then
		OutPut "FAIL" "Backup Failed"
	else
		OutPut "INFO" "Backup Completed"
	fi
}



Do_Incremental_Backup() {

	OutPut "INFO" "Incremental Backup Started"
        if [ ! -d $BackUpLocation/FULL ]
        then
                OutPut "WARN" "No Full Backup. Exiting."
                exit -1
        fi
	OutPut "INFO" "... Checking Last Incremental Backup"
        if [ ! -f $BackUpLocation/last_incremental_number ]; then
            NUMBER=1
		OutPut "INFO" "... this is the first incremental backup"
        else
            NUMBER=$(($(cat $BackUpLocation/last_incremental_number) + 1))
		OutPut "INFO" "... creating incremental backup $NUMBER"
        fi

	OutPut "INFO" "... starting incremental backup $NUMBER"
        if [ $NUMBER -eq 1 ]
        then
                $backup_software $Back_Up_Settings --backup --target-dir $BackUpLocation/inc$NUMBER --incremental-basedir $BackUpLocation/FULL
		echo "HERE $backup_software $Back_Up_Settings --backup --target-dir $BackUpLocation/inc$NUMBER --incremental-basedir=$BackUpLocation/FULL"
        else
                $backup_software $Back_Up_Settings --backup --target-dir $BackUpLocation/inc$NUMBER --incremental-basedir $BackUpLocation/inc$(($NUMBER - 1))
		echo "THERE $backup_software $Back_Up_Settings --backup --target-dir $BackUpLocation/inc$NUMBER --incremental-basedir $BackUpLocation/inc$(($NUMBER - 1))"
        fi
        date
	OutPut "INFO" "... finished incremental backup $NUMBER"
        echo $NUMBER > $BackUpLocation/last_incremental_number
	OutPut "INFO" "Incremental Backup Completed"
}

Do_Restore() {

        echo "WARNING: are you sure this is what you want to do?"
        select yn in "Yes" "No"; do
            case $yn in
                Yes ) break;;
                No ) echo "Restore Not Carried Out"; exit;;
            esac
        done

	OutPut "INFO" "Restore Selected"
	OutPut "INFO" "Stopping MariaDB"
	systemctl stop mariadb
	OutPut "INFO" "Removing installation dirs $MySqlDataDir"
	cd /tmp # Incase the following fails
	if [ -d $MySqlDataDir ]
	then
		rm -rf $MySqlDataDir/*
		OutPut "INFO" "... removed $MySqlDataDir/*"
	fi
	#rm -rf /var/log/mysql/innodblogs/*
	cd ~

	OutPut "INFO" "... Applying Logs to Backup"
        $backup_software --prepare --target-dir $BackUpLocation/FULL --user=$DB_User --password=$DB_Pass --apply-log-only

        lv_inc_backup=1

        while [ -d $BackUpLocation/inc$lv_inc_backup ]
        do
                OutPut "INFO" "... Applying Logs to Backup $lv_inc_backup"
		$backup_software --prepare --target-dir $BackUpLocation/FULL --user=$DB_User --password=$DB_Pass --incremental-dir $BackUpLocation/inc$lv_inc_backup --apply-log-only
		lv_inc_backup=$(($lv_inc_backup+1))
	done

	OutPut "INFO" "... backing up current installation"
	tar -czvf $BackUpLocation/mysqlBackup$TimeStamp.tar $MySqlDataDir
	OutPut "INFO" "... removing existing data directory"
        rm -rf $MySqlDataDir/*
	OutPut "INFO" "... copying back full backup"
        $backup_software --copy-back --force-non-empty-directories --target-dir $BackUpLocation/FULL --datadir $MySqlDataDir
	OutPut "INFO" "... setting permissions..."
        chown -R mysql:mysql $MySqlDataDir
	OutPut "INFO" "Restarting MariaDB"
	systemctl start mariadb
	OutPut "INFO" "Restore Complete"

}


###############
# Entry Point #
###############

usage()
{
cat << EOF
usage: $0 options
example ./$SCRIPTNAME -t Full

OPTIONS:
        -h      Show this message
        -t      Full
                Incremental
                Restore

EOF
}

while getopts "ht:" OPTION
do
 case $OPTION in
     h)
            usage
            exit 0
            ;;
     t)
            CHECK=$OPTARG
            ;;
    ?)
            usage
            exit 0
            ;;
 esac
done

init
case $CHECK in
        Full)
                Do_Full_Backup
        ;;
        Incremental)
                Do_Incremental_Backup
        ;;
        Restore)
                Do_Restore
        ;;
        *)
                usage
                exit 0
        ;;
esac


# Return the Output
returnOutPut
