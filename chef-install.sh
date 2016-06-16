#!/bin/bash
set -e

# Variables
## AWS
AMI=REPLACE_ME
ITYPE=t2.micro
SUBNET=REPLACE_ME

## Colors
GREEN="\033[1;32m"
BOLD="\033[1m"
RED="\033[1;31m"
NC="\033[0m"

## Chef
chef_link=https://packages.chef.io/stable/ubuntu/12.04/chefdk_0.14.25-1_amd64.deb
chef_client='cookbook_path "/var/chef/cookbooks"
local_mode  "true"
log_level :info'
railsapp='{
  "run_list": [ "recipe[railsapp::rails]" ]
}'

# Functions
function retry {
  local n=1
  local max=10
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

function chef_configuration {
  echo -e "$GREEN Downloading and installing chefdk. $NC"
  ssh ubuntu@$1 "wget --no-check-certificate -q $chef_link && sudo dpkg -i chefdk_0.14.25-1_amd64.deb > /dev/null && rm chefdk_0.14.25-1_amd64.deb"

  echo -e "$GREEN Creating chef configuration list. $NC"
  ssh ubuntu@$1 "sudo mkdir -p /var/chef"
  echo -e "$chef_client" | ssh ubuntu@$1 "sudo tee /var/chef/client.rb"

  echo -e "$GREEN Cloning cookbooks to server. $NC"
  ssh ubuntu@$1 "sudo apt-get -yq update > /dev/null 2>&1 && sudo apt-get -yq install git > /dev/null 2>&1"
  ssh ubuntu@$1 "git clone https://github.com/midN/chef_cookbooks.git /home/ubuntu/cookbooks"
  ssh ubuntu@$1 "sudo cp -aT /home/ubuntu/cookbooks /var/chef/cookbooks && sudo rm -rf /home/ubuntu/cookbooks"

  echo -e "$GREEN Adding node info to Chef. $NC"
  echo -e "$railsapp" | ssh ubuntu@$1 "sudo tee /var/chef/base.json"

  echo -e "$GREEN Installing berks dependencies. $NC"
  ssh ubuntu@$1 "export LC_CTYPE=en_US.UTF-8; cd /var/chef/cookbooks/railsapp && berks vendor"
  set +e
  ssh ubuntu@$1 "mv /var/chef/cookbooks/railsapp/berks-cookbooks/* /var/chef/cookbooks" 2> /dev/null
  ssh ubuntu@$1 "rm -rf /var/chef/cookbooks/railsapp/berks-cookbooks"
  set -e

  echo -e "$GREEN Running chef-cliet in local mode. $NC"
  ssh ubuntu@$1 "sudo chef-client -c /var/chef/client.rb -j /var/chef/base.json"
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
  instance_id=$(aws ec2 run-instances --subnet-id $SUBNET --image-id $AMI --count 1 --instance-type $ITYPE --key-name $keypair --output text --query 'Instances[*].InstanceId')
  aws ec2 create-tags --resources $instance_id --tags Key=Name,Value="SuchWowApp"

  echo -e "$GREEN Instance launched, waiting for it to boot. $NC"
  aws ec2 wait instance-running --instance-ids $instance_id

  echo -e "$GREEN Instance is running! $NC"
  instance_ip=$(aws ec2 describe-instances --instance-ids $instance_id --output text --query 'Reservations[*].Instances[*].PublicIpAddress')
  echo -e "$GREEN Booted up AWS instance might be still not SSH accessible for a while. Retrying SSH for 5 times if it doesn't work. $NC"
  retry ssh -q ubuntu@$instance_ip exit

  echo -e "$GREEN Instance is finally SSH accessible, running chef configuration. $NC"
  chef_configuration $instance_ip $imagetype

  echo -e "$GREEN Chef setup has finished. $NC"

  echo -e "$GREEN Creating ssl cert, load-balancer. Using first found Subnet. $NC"
  self_signed_ssl
  sslarn=`aws iam upload-server-certificate --server-certificate-name suchwowapp --certificate-body file://server.crt --private-key file://server.key --output text --query 'ServerCertificateMetadata.Arn'`

  sleep 15

  subnet=`aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text`
  dns=`aws elb create-load-balancer --load-balancer-name suchwowapp --listeners "Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80" "Protocol=HTTPS,LoadBalancerPort=443,InstanceProtocol=HTTP,InstancePort=80,SSLCertificateId=$sslarn" --subnets $subnet --output text --query 'DNSName'`

  echo -e "$GREEN Adding instance to ELB. $NC"
  aws elb configure-health-check --load-balancer-name suchwowapp --health-check Target=HTTP:8080/,Interval=30,UnhealthyThreshold=2,HealthyThreshold=2,Timeout=10
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
