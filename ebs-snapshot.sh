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

createAMI() {
        #To create a unique AMI name for this script
        INST_NAME="$(aws ec2 describe-instances --region $region --filters Name=instance-id,Values=$instance_id --query 'Reservations[*].Instances[*].Tags[?Key==`Name`].Value')"
        INST_TAG="BLOGS_IR_SEM_ERRO_B"_"$(date +%d%b%y)"
        echo -e "Starting the Daily AMI creation: $INST_TAG\n"

        #To create AMI of defined instance
        AMI_ID=$(aws ec2 create-image --region $region --instance-id "$instance_id" --name "$INST_TAG" --description "$instance_id"_"$(date +%d%b%y)" --no-reboot)
        echo "New AMI Id is: $AMI_ID"
        echo "Waiting for 1 minute"
        sleep 60

        #Renaming AMI and its Snapshots
        # aws ec2 create-tags --region $region --resources "$AMI_ID" --tags Key=CreatedBy,Value=AutomatedBackup
        # aws ec2 describe-images --region $region --image-id "$AMI_ID" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n' > /tmp/newsnaplist.txt
        # while read SNAP_ID; do
        #         aws ec2 create-tags --region $region --resources "$SNAP_ID" --tags Key=CreatedBy,Value=AutomatedBackup
        # done < /tmp/newsnaplist.txt
}

deleteAMI() {
        #Finding AMI older than n which needed to be removed
        if [[ $(aws ec2 describe-images --region $region --filters Name=description,Values="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n') ]]
        then
                AMIDELTAG="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')"

                #Finding Image ID of instance which needed to be Deregistered
                AMIDELETE=$(aws ec2 describe-images --region $region --filters Name=description,Values="$AMIDELTAG" --query 'Images[*].ImageId' | tr -s '\t' '\n')

                #Find the snapshots attached to the Image need to be Deregister
                aws ec2 describe-images --region $region --filters Name=image-id,Values="$AMIDELETE" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n' > /tmp/snap.txt

                #Deregistering the AMI
                aws ec2 deregister-image --region $region --image-id "$AMIDELETE"

                #Deleting snapshots attached to AMI
                while read SNAP_DEL; do
                        aws ec2 delete-snapshot --region $region --snapshot-id "$SNAP_DEL"
                done < /tmp/snap.txt
        else
                echo "No AMI present"
        fi
}

## SCRIPT COMMANDS ##
log_setup
prerequisite_check
createAMI
deleteAMI

######### Removing temporary files
rm -f /tmp/snap.txt /tmp/newsnaplist.txt

# Merging the Snap Creation and Deletion Data
cat $createAMI $deleteAMI > /var/log/mail_report

# Sending the mail Update
cat /var/log/mail_report | mail -s "Snapshots AWS Status" jsantos@horadolar.com.br
