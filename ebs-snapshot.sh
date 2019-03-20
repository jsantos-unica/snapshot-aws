#!/bin/bash
export PATH=$PATH:/usr/local/bin/:/usr/bin

# Safety feature: exit script if error is returned, or if variables not set.
# Exit if a pipeline results in an error.
set -ue
set -o pipefail

## Variable Declartions ##

# Get Instance Details
instance_id=$(wget -q -O- http://169.254.169.254/latest/meta-data/instance-id)
region=$(wget -q -O- http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's/\([1-9]\).$/\1/g')

# Set Logging Options
logfile="/var/log/ebs-snapshot.log"
logfile_max_lines="5000"

# How many days do you wish to retain backups for? Default: 7 days
retention_days="7"
retention_date_in_seconds=$(date +%s --date "$retention_days days ago")

## Function Declarations ##

# Function: Setup logfile and redirect stdout/stderr.
log_setup() {
    # Check if logfile exists and is writable.
    ( [ -e "$logfile" ] || touch "$logfile" ) && [ ! -w "$logfile" ] && echo "ERROR: Cannot write to $logfile. Check permissions or sudo access." && exit 1

    tmplog=$(tail -n $logfile_max_lines $logfile 2>/dev/null) && echo "${tmplog}" > $logfile
    exec > >(tee -a $logfile)
    exec 2>&1
}

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}

# Function: Confirm that the AWS CLI and related tools are installed.
prerequisite_check() {
	for prerequisite in aws wget; do
		hash $prerequisite &> /dev/null
		if [[ $? == 1 ]]; then
			echo "In order to use this script, the executable \"$prerequisite\" must be installed." 1>&2; exit 70
		fi
	done
}

deleteAMI() {
        for volume_id in $volume_list; do
                teste = $(aws ec2 describe-images --region $region --output=text --filters Name=description,Values="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId')
                echo teste

                ami_list=$(aws ec2 describe-images --region $region --output=text --filters "Name=volume-id,Values=$volume_id" "Name=tag:CreatedBy,Values=AutomatedBackup" --query Snapshots[].SnapshotId)
                echo ami_list
		
                # for snapshot in $ami_list; do
		# 	log "Checking $snapshot..."
		# 	# Check age of snapshot
		# 	snapshot_date=$(aws ec2 describe-images --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
                #         echo snapshot_date

		# 	snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
                #         echo snapshot_date_in_seconds

		# 	snapshot_description=$(aws ec2 describe-images --snapshot-id $snapshot --region $region --query Snapshots[].Description)
                #         echo snapshot_description

		# 	if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
		# 		log "DELETING snapshot $snapshot. Description: $snapshot_description ..."
		# 		aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
		# 	else
		# 		log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
		# 	fi
		# done

		# snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=volume-id,Values=$volume_id" "Name=tag:CreatedBy,Values=AutomatedBackup" --query Snapshots[].SnapshotId)
                # echo snapshot_list
		# for snapshot in $snapshot_list; do
		# 	log "Checking $snapshot..."
		# 	# Check age of snapshot
		# 	snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
                #         echo snapshot_date

		# 	snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
                #         echo snapshot_date_in_seconds

		# 	snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)
                #         echo snapshot_description

		# 	if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
		# 		log "DELETING snapshot $snapshot. Description: $snapshot_description ..."
		# 		aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
		# 	else
		# 		log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
		# 	fi
		# done
	done
}

## SCRIPT COMMANDS ##
log_setup
prerequisite_check

# Grab all volume IDs attached to this instance
volume_list=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instance_id --query Volumes[].VolumeId --output text)
echo $volume_list

deleteAMI

######### Removing temporary files
rm -f /tmp/snap.txt /tmp/newsnaplist.txt
