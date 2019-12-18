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
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh
# Add the helm repositories
helm init
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo add flowable https://flowable.org/helm/
helm repo update

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
      export PGPASSWORD='${db_password}'
      DB_NAME=`echo $CLIENT_NAME | sed -r 's/[-]+/_/g'`
      echo "CREATE DATABASE $DB_NAME;" | psql -h '${db_host}' -d '${db_name}' -U '${db_user}'
      echo "CREATE SCHEMA IF NOT EXISTS flowable AUTHORIZATION ${db_user};" | psql -h '${db_host}' -d "$DB_NAME" -U '${db_user}'
      echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Creating RDS database $DB_NAME for $CLIENT_NAME ($line)" >> $LOG_FILE
      helm repo add flowable https://flowable.org/helm/
      helm repo update
      helm install flowable/flowable \
         --name-template flowable \
         --set host.external="$CLIENT_NAME.labs.zaizicloud.net" \
         --set database.username="${db_user}" \
         --set database.password="$(echo $PGPASSWORD | sed -e 's#[()&\\]#\\&#g')" \
         --set database.datasourceDriverClassName="org.postgresql.Driver" \
         --set database.datasourceUrl="jdbc:postgresql://${db_host}:5432/$DB_NAME?currentSchema=flowable" \
         --set postgres.enabled=false  \
         --set ingress.enabled=false \
         --set admin.enabled=true \
         -n $CLIENT_NAME
      echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Deploying flowable for $CLIENT_NAME ($line)" >> $LOG_FILE
cat <<EOF | kubectl apply -f -
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: $CLIENT_NAME-ingress
  namespace: $CLIENT_NAME
  annotations:
    external-dns.alpha.kubernetes.io/alias: "true"
    kubernetes.io/ingress.class: "nginx-ingress"
    nginx.ingress.kubernetes.io/configuration-snippet: |
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    nginx.ingress.kubernetes.io/rewrite-target: /\$1
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
  labels:
    app.kubernetes.io/instance: flowable
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: ingress
    helm.sh/chart: flowable-0.1.0
spec:
  rules:
  - host: $CLIENT_NAME.labs.zaizicloud.net
    http:
      paths:
      - backend:
          serviceName: flowable-idm
          servicePort: 8080
        path: /flowable-idm/?(.*)
      - backend:
          serviceName: flowable-modeler
          servicePort: 8888
        path: /flowable-modeler/?(.*)
      - backend:
          serviceName: flowable-task
          servicePort: 9999
        path: /flowable-task/?(.*)
      - backend:
          serviceName: flowable-admin
          servicePort: 9988
        path: /flowable-admin/?(.*)
      EOF
      echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Deploying ingress for $CLIENT_NAME ($line)" >> $LOG_FILE
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
    kubectl delete ing $CLIENT_NAME-ingress -n $CLIENT_NAME
    echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Removing ingress for $CLIENT_NAME ($line)" >> $LOG_FILE
    helm delete flowable -n $CLIENT_NAME
    echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Removing flowable for $CLIENT_NAME ($line)" >> $LOG_FILE
    kubectl delete namespace $CLIENT_NAME
    echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Removing K8 namespace for $CLIENT_NAME ($line)" >> $LOG_FILE
    export PGPASSWORD='${db_password}'
    DB_NAME=`echo $CLIENT_NAME | sed -r 's/[-]+/_/g'`
    echo "DROP DATABASE $DB_NAME" | psql -h '${db_host}' -d '${db_name}' -U '${db_user}'
    echo "`date --date="today" "+%Y-%m-%d %H-%M-%S"`: Dropping RDS database for $CLIENT_NAME ($line)" >> $LOG_FILE
  done < ~/clients_to_remove
  comm -3 ~/clients_onboarded ~/clients_to_remove | sed "s/\t//g" > ~/tmp && mv ~/tmp ~/clients_onboarded
fi

EOF

chmod 700 /usr/bin/bastion/sync_clients

###########################################
## SCHEDULE SCRIPTS AND SECURITY UPDATES ##
###########################################

cat > ~/mycron << EOF
HOME=/root
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin
*/5 * * * * /usr/bin/bastion/sync_s3
*/2 * * * * /usr/bin/bastion/sync_users
*/2 * * * * export KUBECONFIG=~/.kube/config && /usr/bin/bastion/sync_clients
0 0 * * * yum -y update --security
EOF
crontab ~/mycron
rm ~/mycron
