#!/bin/bash
set -e

# Variables
## AWS
AMI=ami-47a23a30
ITYPE=t2.micro

## Colors
GREEN="\033[1;32m"
BOLD="\033[1m"
RED="\033[1;31m"
NC="\033[0m"

# Functions
function retry {
  local n=1
  local max=5
  local delay=5
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max:"
        sleep $delay;
      else
        echo -e "The command has failed after $n attempts." >&2 && exit 1
      fi
    }
  done
}

function self_signed_ssl {
  export PASSPHRASE=1234
  subj="/C=US/ST=Denial/L=Springfield/O=Dis/CN=suchwowapp.com"
  openssl genrsa -des3 -out server.key -passout env:PASSPHRASE 2048
  openssl req -new -batch -subj "$(echo -n "$subj" | tr "\n" "/")" -key server.key -out server.csr -passin env:PASSPHRASE
  openssl rsa -in server.key -out server.key -passin env:PASSPHRASE
  openssl x509 -req -days 3650 -in server.csr -signkey server.key -out server.crt
}

# Script
echo -e "$BOLD NB! Your 'default' security group in AWS must allow SSH login from your IP. $NC"
echo -e "$BOLD Verifying AWS connection... $NC"
if aws ec2 describe-instances > /dev/null; then
  echo -e "$GREEN All good, continuing. $NC"
  # Get Keypair
  read -p "Please provide a valid Key-Pair name to be used for SSHing to instance: " keypair
  aws ec2 describe-key-pairs --key-names $keypair --query 'KeyPairs[0].KeyName' --output text > /dev/null
  echo -e "$GREEN Keypair exists, Continuing. $NC"

  # Create a new instance
  echo -e "$GREEN Creating a new instance. $NC"
  instance_id=$(aws ec2 run-instances --image-id $AMI --count 1 --instance-type $ITYPE --key-name $keypair --output text --query 'Instances[*].InstanceId')
  aws ec2 create-tags --resources $instance_id --tags Key=Name,Value="SuchWowApp"

  echo -e "$GREEN Instance launched, waiting for it to boot. $NC"
  aws ec2 wait instance-running --instance-ids $instance_id

  echo -e "$GREEN Instance is running! $NC"
  instance_ip=$(aws ec2 describe-instances --instance-ids $instance_id --output text --query 'Reservations[*].Instances[*].PublicIpAddress')
  echo -e "$GREEN Booted up AWS instance might be still not SSH accessible for a while. Retrying SSH for 5 times if it doesn't work. $NC"
  retry ssh -q ubuntu@$instance_ip exit

  echo -e "$GREEN Instance is finally SSH accessible, installing docker. $NC"
  ssh ubuntu@$instance_ip "sudo apt-get update -q && sudo apt-get -yq install curl git apt-transport-https ca-certificates"
  ssh ubuntu@$instance_ip "sudo apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D"
  ssh ubuntu@$instance_ip "echo 'deb https://apt.dockerproject.org/repo ubuntu-trusty main' | sudo tee /etc/apt/sources.list.d/docker.list"
  ssh ubuntu@$instance_ip "sudo apt-get update -q && sudo apt-get -yq install docker-engine"

  echo -e "$GREEN Pulling latest docker image. $NC"
  ssh ubuntu@$instance_ip "sudo mkdir -p /opt/webapps/suchwowapp"
  ssh ubuntu@$instance_ip "sudo git clone https://github.com/midN/rails5app.git /opt/webapps/suchwowapp"
  ssh ubuntu@$instance_ip "sudo docker pull m1dn/suchwowapp:master"

  echo -e "$GREEN Running Rails app + Postgres $NC"
  ssh ubuntu@$instance_ip "sudo docker run -d --name pg -e POSTGRES_USER=rails5app -e POSTGRES_DB=rails5app_production -e POSTGRES_PASSWORD=thisisnotthebestpasswordintheworldthisisjustatribute postgres"
  ssh ubuntu@$instance_ip "sudo docker run -d --name suchwowapp -e RAILS5APP_DATABASE_HOST=pg -e RAILS5APP_DATABASE_PASSWORD=thisisnotthebestpasswordintheworldthisisjustatribute -e DISABLE_DATABASE_ENVIRONMENT_CHECK=1 --link pg:pg -p 8080:8080 m1dn/suchwowapp:master 'bundle exec rake db:schema:load && bundle exec rake db:migrate && bundle exec unicorn -p 8080'"
  ssh ubuntu@$instance_ip "sudo docker run -d --name nginx --link suchwowapp:suchwowapp -p 80:80 -p 443:443 -v /opt/webapps/suchwowapp/files/nginx.conf:/etc/nginx/conf.d/default.conf nginx"

  echo -e "$GREEN Creating ssl cert, load-balancer. Using first found Subnet. $NC"
  self_signed_ssl
  sslarn=`aws iam upload-server-certificate --server-certificate-name suchwowapp --certificate-body file://server.crt --private-key file://server.key --output text --query 'ServerCertificateMetadata.Arn'`

  sleep 15

  subnet=`aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text`
  dns=`aws elb create-load-balancer --load-balancer-name suchwowapp --listeners "Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80" "Protocol=HTTPS,LoadBalancerPort=443,InstanceProtocol=HTTP,InstancePort=80,SSLCertificateId=$sslarn" --subnets $subnet --output text --query 'DNSName'`

  echo -e "$GREEN Adding instance to ELB. $NC"
  aws elb configure-health-check --load-balancer-name suchwowapp --health-check Target=HTTP:8080/,Interval=30,UnhealthyThreshold=2,HealthyThreshold=2,Timeout=3
  aws elb register-instances-with-load-balancer --load-balancer-name suchwowapp --instances $instance_id

  echo -e "$GREEN Waiting for ELB to become healthy. $NC"
  while true; do
      STATUS="$(aws elb describe-instance-health --load-balancer-name suchwowapp --output text --query 'InstanceStates[0].State')"
      if [ "$STATUS" = "InService" ]; then break; fi
      sleep 7
      echo -e "Current status: $STATUS \n"
  done

  echo -e "$GREEN You can access your instance on https://$dns. $NC"
else
  echo -e "$RED Could not verify AWS connection, verify it works and try again. Verified by running:"
  echo -e " aws ec2 describe-instances $NC"
fi
