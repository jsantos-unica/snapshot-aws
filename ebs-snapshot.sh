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

alias aws=''$(which aws)' --output text --region us-east-1a'
shopt -s expand_aliases

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

# Function: Snapshot all volumes attached to this instance.
snapshot_volumes() {
	for volume_id in $volume_list; do
		log "Volume ID is $volume_id"

		# Get the attched device name to add to the description so we can easily tell which volume this is.
		device_name=$(aws ec2 describe-volumes --region $region --output=text --volume-ids $volume_id --query 'Volumes[0].{Devices:Attachments[0].Device}')

		# Take a snapshot of the current volume, and capture the resulting snapshot ID
		snapshot_description="$(hostname)-$device_name-backup-$(date +%Y-%m-%d)"

		snapshot_id=$(aws ec2 create-snapshot --region $region --output=text --description $snapshot_description --volume-id $volume_id --query SnapshotId)
		log "New snapshot is $snapshot_id"
	 
		# Add a "CreatedBy:AutomatedBackup" tag to the resulting snapshot.
		# Why? Because we only want to purge snapshots taken by the script later, and not delete snapshots manually taken.
		aws ec2 create-tags --region $region --resource $snapshot_id --tags Key=CreatedBy,Value=AutomatedBackup
	done
}

# Function: Cleanup all snapshots associated with this instance that are older than $retention_days
cleanup_snapshots() {
	for volume_id in $volume_list; do
		snapshot_list=$(aws ec2 describe-snapshots --region $region --output=text --filters "Name=volume-id,Values=$volume_id" "Name=tag:CreatedBy,Values=AutomatedBackup" --query Snapshots[].SnapshotId)
		for snapshot in $snapshot_list; do
			log "Checking $snapshot..."
			# Check age of snapshot
			snapshot_date=$(aws ec2 describe-snapshots --region $region --output=text --snapshot-ids $snapshot --query Snapshots[].StartTime | awk -F "T" '{printf "%s\n", $1}')
			snapshot_date_in_seconds=$(date "--date=$snapshot_date" +%s)
			snapshot_description=$(aws ec2 describe-snapshots --snapshot-id $snapshot --region $region --query Snapshots[].Description)

			if (( $snapshot_date_in_seconds <= $retention_date_in_seconds )); then
				log "DELETING snapshot $snapshot. Description: $snapshot_description ..."
				aws ec2 delete-snapshot --region $region --snapshot-id $snapshot
			else
				log "Not deleting snapshot $snapshot. Description: $snapshot_description ..."
			fi
		done
	done
}

# createAMI() {
#         #To create a unique AMI name for this script
#         INST_NAME="$(aws ec2 describe-instances --filters Name=instance-id,Values=$instance_id --query 'Reservations[*].Instances[*].Tags[?Key==`Name`].Value')"
#         INST_TAG="$INST_NAME"_"$(date +%d%b%y)"
#         echo -e "Starting the Daily AMI creation: $INST_TAG\n"

#         #To create AMI of defined instance
#         AMI_ID=$(aws ec2 create-image --instance-id "$instance_id" --name "$INST_TAG" --description "$instance_id"_"$(date +%d%b%y)" --no-reboot)
#         echo "New AMI Id is: $AMI_ID"
#         echo "Waiting for 0.5 minutes"
#         sleep 30

#         #Renaming AMI and its Snapshots
#         aws ec2 create-tags --resources "$AMI_ID" --tags Key=Name,Value="$INST_TAG"
#         aws ec2 describe-images --image-id "$AMI_ID" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n' > /tmp/newsnaplist.txt
#         while read SNAP_ID; do
#                 aws ec2 create-tags --resources "$SNAP_ID" --tags Key=Name,Value="$INST_TAG"
#         done < /tmp/newsnaplist.txt

#         #Finding AMI older than n which needed to be removed
#         if [[ $(aws ec2 describe-images --filters Name=description,Values="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n') ]]
#         then
#                 AMIDELTAG="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')"

#                 #Finding Image ID of instance which needed to be Deregistered
#                 AMIDELETE=$(aws ec2 describe-images --filters Name=description,Values="$AMIDELTAG" --query 'Images[*].ImageId' | tr -s '\t' '\n')

#                 #Find the snapshots attached to the Image need to be Deregister
#                 aws ec2 describe-images --filters Name=image-id,Values="$AMIDELETE" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n' > /tmp/snap.txt

#                 #Deregistering the AMI
#                 aws ec2 deregister-image --image-id "$AMIDELETE"

#                 #Deleting snapshots attached to AMI
#                 while read SNAP_DEL; do
#                         aws ec2 delete-snapshot --snapshot-id "$SNAP_DEL"
#                 done < /tmp/snap.txt
#         else
#                 echo "No AMI present"
#         fi
# }

## SCRIPT COMMANDS ##

log_setup
prerequisite_check

# Grab all volume IDs attached to this instance
volume_list=$(aws ec2 describe-volumes --region $region --filters Name=attachment.instance-id,Values=$instance_id --query Volumes[].VolumeId --output text)

# snapshot_volumes
# cleanup_snapshots
