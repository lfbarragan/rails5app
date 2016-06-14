#!/bin/bash
set -e

# Variables
## Colors
GREEN="\033[1;32m"
BOLD="\033[1m"
RED="\033[1;31m"
NC="\033[0m"

echo -e "$RED Deleting ELB $NC"
aws elb delete-load-balancer --load-balancer-name suchwowapp

sleep 2

echo -e "$RED Deleting SSL Cert $NC"
aws iam delete-server-certificate --server-certificate-name suchwowapp

echo -e "$RED Deleting EC2 Instance $NC"
ec2id=`aws ec2 describe-instances --filter "Name=tag-value,Values=SuchWowApp" --filter "Name=instance-state-name,Values=running" --output text --query 'Reservations[0].Instances[0].InstanceId'`
aws ec2 terminate-instances --instance-ids $ec2id
