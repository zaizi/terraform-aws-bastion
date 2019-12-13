#!/bin/bash -x
yum -y update --security

##########################
## INSTALL REQUIRED SOFTWARE
##########################
# Install extra packages
amazon-linux-extras install epel -y
# Install terraform
yum install wget unzip -y
wget https://releases.hashicorp.com/terraform/0.12.18/terraform_0.12.18_linux_amd64.zip
unzip terraform_0.12.18_linux_amd64.zip
mv ./terraform /usr/local/bin/terraform
# Install kubectl 
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
yum install kubectl -y
# Install postgresql client
yum install postgresql -y
# Install aws-iam-authenticator
curl -o aws-iam-authenticator https://amazon-eks.s3-us-west-2.amazonaws.com/1.13.7/2019-06-11/bin/linux/amd64/aws-iam-authenticator
chmod +x aws-iam-authenticator
mv ./aws-iam-authenticator /usr/local/bin/aws-iam-authenticator
# Install Helm
su ec2-user
cd /home/ec2-user/
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
sudo chown ec2-user:ec2-user ./get_helm.sh
chmod 700 get_helm.sh
sudo ./get_helm.sh
exit

##########################
## Create a kubeconfig for Amazon EKS
##########################
# su ec2-user
# cd /home/ec2-user/
# mkdir ~/.aws
# cat <<EOF > ~/.aws/credentials
# [default]
# aws_access_key_id = 
# aws_secret_access_key = 
# EOF
# cat <<EOF > ~/.aws/config
# [default]
# region = eu-west-2
# output = json
# EOF
# aws eks --region eu-west-2 update-kubeconfig --name dpa-eks-cluster-stage
# export KUBECONFIG=$KUBECONFIG:~/.kube/config
# exit

##########################
## ENABLE SSH RECORDING ##
##########################

# Create a new folder for the log files
mkdir /var/log/bastion

# Allow ec2-user only to access this folder and its content
chown ec2-user:ec2-user /var/log/bastion
chmod -R 770 /var/log/bastion
setfacl -Rdm other:0 /var/log/bastion

# Make OpenSSH execute a custom script on logins
echo -e "\\nForceCommand /usr/bin/bastion/shell" >> /etc/ssh/sshd_config

# Block some SSH features that bastion host users could use to circumvent the solution
awk '!/X11Forwarding/' /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
echo "X11Forwarding no" >> /etc/ssh/sshd_config

mkdir /usr/bin/bastion

cat > /usr/bin/bastion/shell << 'EOF'

# Check that the SSH client did not supply a command
if [[ -z $SSH_ORIGINAL_COMMAND ]]; then

  # The format of log files is /var/log/bastion/YYYY-MM-DD_HH-MM-SS_user
  LOG_FILE="`date --date="today" "+%Y-%m-%d_%H-%M-%S"`_`whoami`"
  LOG_DIR="/var/log/bastion/"

  # Print a welcome message
  echo ""
  echo "NOTE: This SSH session will be recorded"
  echo "AUDIT KEY: $LOG_FILE"
  echo ""

  # I suffix the log file name with a random string. I explain why later on.
  SUFFIX=`mktemp -u _XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`

  # Wrap an interactive shell into "script" to record the SSH session
  script -qf --timing=$LOG_DIR$LOG_FILE$SUFFIX.time $LOG_DIR$LOG_FILE$SUFFIX.data --command=/bin/bash

else

  # The "script" program could be circumvented with some commands (e.g. bash, nc).
  # Therefore, I intentionally prevent users from supplying commands.

  echo "This bastion supports interactive sessions only. Do not supply a command"
  exit 1

fi

EOF

# Make the custom script executable
chmod a+x /usr/bin/bastion/shell

# Bastion host users could overwrite and tamper with an existing log file using "script" if
# they knew the exact file name. I take several measures to obfuscate the file name:
# 1. Add a random suffix to the log file name.
# 2. Prevent bastion host users from listing the folder containing log files. This is done
#    by changing the group owner of "script" and setting GID.
chown root:ec2-user /usr/bin/script
chmod g+s /usr/bin/script

# 3. Prevent bastion host users from viewing processes owned by other users, because the log
#    file name is one of the "script" execution parameters.
mount -o remount,rw,hidepid=2 /proc
awk '!/proc/' /etc/fstab > temp && mv temp /etc/fstab
echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab

# Restart the SSH service to apply /etc/ssh/sshd_config modifications.
service sshd restart

############################
## EXPORT LOG FILES TO S3 ##
############################

cat > /usr/bin/bastion/sync_s3 << 'EOF'
#!/usr/bin/env bash

# Copy log files to S3 with server-side encryption enabled.
# Then, if successful, delete log files that are older than a day.
LOG_DIR="/var/log/bastion/"
aws s3 cp $LOG_DIR s3://${bucket_name}/logs/ --sse --region ${aws_region} --recursive && find $LOG_DIR* -mtime +1 -exec rm {} \;

EOF

chmod 700 /usr/bin/bastion/sync_s3

#######################################
## SYNCHRONIZE USERS AND PUBLIC KEYS ##
#######################################

# Bastion host users should log in to the bastion host with their personal SSH key pair.
# The public keys are stored on S3 with the following naming convention: "username.pub".
# This script retrieves the public keys, creates or deletes local user accounts as needed,
# and copies the public key to /home/username/.ssh/authorized_keys

cat > /usr/bin/bastion/sync_users << 'EOF'
#!/usr/bin/env bash

# The file will log user changes
LOG_FILE="/var/log/bastion/users_changelog.txt"

# The function returns the user name from the public key file name.
# Example: public-keys/sshuser.pub => sshuser
get_user_name () {
  echo "$1" | sed -e "s/.*\///g" | sed -e "s/\.pub//g"
}

# For each public key available in the S3 bucket
aws s3api list-objects --bucket ${bucket_name} --prefix public-keys/ --region ${aws_region} --output text --query 'Contents[?Size>`0`].Key' | tr '\t' '\n' > ~/keys_retrieved_from_s3
while read line; do
  USER_NAME="`get_user_name "$line"`"

  # Make sure the user name is alphanumeric
  if [[ "$USER_NAME" =~ ^[a-z][-a-z0-9]*$ ]]; then

    # Create a user account if it does not already exist
    cut -d: -f1 /etc/passwd | grep -qx $USER_NAME
    if [ $? -eq 1 ]; then
      /usr/sbin/adduser $USER_NAME && \
      mkdir -m 700 /home/$USER_NAME/.ssh && \
      chown $USER_NAME:$USER_NAME /home/$USER_NAME/.ssh && \
      echo "$line" >> ~/keys_installed && \
      echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Creating user account for $USER_NAME ($line)" >> $LOG_FILE
    fi

    # Copy the public key from S3, if an user account was created from this key
    if [ -f ~/keys_installed ]; then
      grep -qx "$line" ~/keys_installed
      if [ $? -eq 0 ]; then
        aws s3 cp s3://${bucket_name}/$line /home/$USER_NAME/.ssh/authorized_keys --region ${aws_region}
        chmod 600 /home/$USER_NAME/.ssh/authorized_keys
        chown $USER_NAME:$USER_NAME /home/$USER_NAME/.ssh/authorized_keys
      fi
    fi

  fi
done < ~/keys_retrieved_from_s3

# Remove user accounts whose public key was deleted from S3
if [ -f ~/keys_installed ]; then
  sort -uo ~/keys_installed ~/keys_installed
  sort -uo ~/keys_retrieved_from_s3 ~/keys_retrieved_from_s3
  comm -13 ~/keys_retrieved_from_s3 ~/keys_installed | sed "s/\t//g" > ~/keys_to_remove
  while read line; do
    USER_NAME="`get_user_name "$line"`"
    echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Removing user account for $USER_NAME ($line)" >> $LOG_FILE
    /usr/sbin/userdel -r -f $USER_NAME
  done < ~/keys_to_remove
  comm -3 ~/keys_installed ~/keys_to_remove | sed "s/\t//g" > ~/tmp && mv ~/tmp ~/keys_installed
fi

EOF

chmod 700 /usr/bin/bastion/sync_users

#######################################
## SYNCHRONIZE CLIENTS
#######################################

# The client files are stored on S3 with the following naming convention: "client.txt".
# This script retrieves the client files, creates or deletes k8 namespaces as needed,
# and DB on RDS with the flowable schema

cat > /usr/bin/bastion/sync_clients << 'EOF'
#!/usr/bin/env bash

# The file will log client changes
LOG_FILE="/var/log/bastion/clients_changelog.txt"

# The function returns the client name from the file name.
# Example: clients/client-1.txt => client-1
get_client_name () {
  echo "$1" | sed -e "s/.*\///g" | sed -e "s/\.txt//g"
}

# For each client file available in the S3 bucket
aws s3api list-objects --bucket ${bucket_name} --prefix clients/ --region ${aws_region} --output text --query 'Contents[?Size>`0`].Key' | tr '\t' '\n' > ~/clients_retrieved_from_s3
while read line; do
  CLIENT_NAME="`get_client_name "$line"`"

  # Make sure the user name is alphanumeric
  if [[ "$CLIENT_NAME" =~ ^[a-z][-a-z0-9]*$ ]]; then

    # Create a client K8 namespace and the db if it does not already exist
    kubectl get namespaces | grep -qo $CLIENT_NAME
    if [ $? -eq 1 ]; then
      kubectl create namespace $CLIENT_NAME
      echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Creating K8 namespace for $CLIENT_NAME ($line)" >> $LOG_FILE
      export PGPASSWORD='PQ.Wqr#e2yv\)R%b'
      DB_NAME=`echo $CLIENT_NAME | sed -r 's/[-]+/_/g'`
      echo "CREATE DATABASE $DB_NAME;" | psql -h 'db-stage.labs.zaizicloud.net' -d 'dpa_stage' -U 'dpa'
      echo "CREATE SCHEMA IF NOT EXISTS flowable AUTHORIZATION dpa;" | psql -h 'db-stage.labs.zaizicloud.net' -d "$DB_NAME" -U 'dpa'
      echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Creating RDS database $DB_NAME for $CLIENT_NAME ($line)" >> $LOG_FILE
      echo "$line" >> ~/clients_onboarded
    fi

  fi
done < ~/clients_retrieved_from_s3

# Remove clients whose client file was deleted from S3
if [ -f ~/clients_onboarded ]; then
  sort -uo ~/clients_onboarded ~/clients_onboarded
  sort -uo ~/clients_retrieved_from_s3 ~/clients_retrieved_from_s3
  comm -13 ~/clients_retrieved_from_s3 ~/clients_onboarded | sed "s/\t//g" > ~/clients_to_remove
  while read line; do
    CLIENT_NAME="`get_client_name "$line"`"
    echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Removing K8 namespace and RDS database for $CLIENT_NAME ($line)" >> $LOG_FILE
    kubectl delete namespace $CLIENT_NAME
    export PGPASSWORD='PQ.Wqr#e2yv\)R%b'
    DB_NAME=`echo $CLIENT_NAME | sed -r 's/[-]+/_/g'`
    echo "DROP DATABASE $DB_NAME" | psql -h 'db-stage.labs.zaizicloud.net' -d 'dpa_stage' -U 'dpa'
  done < ~/clients_to_remove
  comm -3 ~/clients_onboarded ~/clients_to_remove | sed "s/\t//g" > ~/tmp && mv ~/tmp ~/clients_onboarded
fi

EOF

chmod 700 /usr/bin/bastion/sync_clients

###########################################
## SCHEDULE SCRIPTS AND SECURITY UPDATES ##
###########################################

cat > ~/mycron << EOF
*/5 * * * * /usr/bin/bastion/sync_s3
*/5 * * * * /usr/bin/bastion/sync_users
*/5 * * * * /usr/bin/bastion/sync_clients
0 0 * * * yum -y update --security
EOF
crontab ~/mycron
rm ~/mycron
