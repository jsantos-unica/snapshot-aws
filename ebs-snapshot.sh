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
retention_days="0"

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

criarAMI() {
        # Script pra criar um nome único para a AMI
        INST_NAME="$(aws ec2 describe-instances --region $region --filters Name=instance-id,Values=$instance_id  --output=text --query 'Reservations[*].Instances[*].Tags[?Key==`Name`].Value')"
        INST_TAG="$INST_NAME"_"$(date +%d%b%y)"
        log "Iniciando a criação da AMI diária: $INST_TAG"

        # Script para criar a AMI da instância definida
        AMI_ID=$(aws ec2 create-image --region $region --instance-id "$instance_id" --name "$INST_TAG" --output=text --description "$instance_id"_"$(date +%d%b%y)" --no-reboot)
        log "Nova AMI ID: $AMI_ID"
        log "Aguarde 30 segundos"
        sleep 30

        # Criar tag na AMI
        log "Criando Tag na AMI..."
        aws ec2 create-tags --region $region --resources "$AMI_ID" --tags Key=CreatedBy,Value=AutomatedBackup
        log "Tag criada com sucesso"

        # Busca os snapshots daquela AMI
        log "Buscando Snapshots..."
        LIST_SNAPS=$(aws ec2 describe-images --region $region --output=text --filters Name=image-id,Values="$AMI_ID" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n')
        log "Lista de snapshots buscada com sucesso"
        log $LIST_SNAPS

        # Cria a Tag 'Key=CreatedBy,Value=AutomatedBackup' nas snapshots
        log "Criando Tags das Snaps..."
        for SNAP_ID in $LIST_SNAPS; do
                log "Criando Tag para a Snap ID: $SNAP_ID"
                aws ec2 create-tags --region $region --resources "$SNAP_ID" --tags Key=CreatedBy,Value=AutomatedBackup
                log "Tag criada com sucesso"
	done

        log "O processo de criação da AMI finalizou com sucesso"
}

deletarAMI() {
        log "Iniciando o processo de deletar a AMI"
        # Procura AMI antiga de3finida na variável 'retention_days'
        if [[ $(aws ec2 describe-images --region $region --filters Name=description,Values="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n') ]]
        then
                # Nome da Tag da AMI
                AMIDELTAG="$instance_id"_"$(date +%d%b%y --date ''$retention_days' days ago')"
                log $AMIDELTAG

                # Encontrar o ID de imagem da instância que precisa ser desregistrada
                AMIDELETE=$(aws ec2 describe-images --region $region  --output=text --filters Name=description,Values="$AMIDELTAG" --query 'Images[*].ImageId' | tr -s '\t' '\n')
                log "AMI ID: $AMIDELETE"

                # Busca os snapshots daquela AMI
                log "Buscando Snapshots..."
                LIST_SNAPS=$(aws ec2 describe-images --region $region --output=text --filters Name=image-id,Values="$AMIDELETE" --query 'Images[*].BlockDeviceMappings[*].Ebs.SnapshotId' | tr -s '\t' '\n')
                log "Lista de snapshots buscada com sucesso"
                log $LIST_SNAPS

                # Desregistra a AMI
                log "Desregistrar AMI..."
                aws ec2 deregister-image --region $region --image-id "$AMIDELETE"
                log "AMI foi desregistrada com sucesso"

                # Deleta os snapshots dessa AMI
                log "Deletando Snapshots..."
                for echo in $LIST_SNAPS; do
                        log "Deletando Snap ID: $echo"
                        aws ec2 delete-snapshot --region $region --snapshot-id "$echo"
                        log "Deletado com sucesso"
	        done
        else
                log "Nenhuma AMI presente"
        fi
        log "Pprocesso de deletar AMI finalizado com sucesso"
}

## SEQUÊNCIA DE COMANDOS ##
if [[ log_setup -ne 0 ]]; then
	echo 'command was successful'
else
	echo "sem erro"
fi
if [[ prerequisite_check -ne 0 ]]; then
	echo 'command was successful'
else
	echo "sem erro"
fi
if [[ createAMI -ne 0 ]]; then
	echo 'command was successful'
else
	echo "sem erro"
fi
if [[ deletarAMI -ne 0]]; then
	echo 'command was successful'
else
	echo "sem erro"
fi
