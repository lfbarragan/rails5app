# Rails5App

> This Rails 5 app was one-liner created with [Rails 5 template](https://github.com/midN/rails_templates/blob/master/rails5/base.rb)

Additional things that were not in Template:
* Unicorn replaced by Puma due to CHEF-DEPLOYMENT reasons.


## Chef Deployment
### Prerequisites:
* AWS CLI configured
* AWS Must have atleast 1 ssh keypair you have access to
* AWS default SG must be accessible on 22, 80, 443, 8080

Run `./chef-deploy.sh`, script will prompt you to enter existing **key-pair**


## Docker Deployment
### Prerequisites:
* AWS CLI configured
* AWS Must have atleast 1 ssh keypair you have access to
* AWS default SG must be accessible on 22, 80, 443, 8080

Run `./docker-deploy.sh`, script will prompt you to enter existing **key-pair**

## Cleanup
In order to cleanup and delete created resources ( ELB, EC2, SSL CERT ) run `./cleanup.sh`
