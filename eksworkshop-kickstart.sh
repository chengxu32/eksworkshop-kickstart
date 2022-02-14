#!/bin/bash

set -e

# Check for prequisites to disable role
echo "Checking for awscliv2!"
if [ $(aws --version 2>&1 | cut -d " " -f1 | cut -d "/" -f2 | cut -d "." -f 1) == "1" ];then
  echo "Installing awscliv2..."
  curl -sLo "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  unzip -q awscliv2.zip
  sudo ./aws/install
  rm -rf ./awscliv2.zip ./aws
else
  echo "awscliv2 already installed..."
fi

# check that IAM caller identity, if not correct check IAM profile first,
echo "Checking Cloud9 IAM Role and caller identity..."
if aws sts get-caller-identity --query Arn | grep -q MasterKey; then
  if curl -s http://169.254.169.254/latest/meta-data/iam/info | grep InstanceProfileArn  | grep -q mod; then
    echo "Turning off AWS Managed Credentials in cloud9..."
    aws cloud9 update-environment  --environment-id $C9_PID --managed-credentials-action DISABLE
    rm -f ${HOME}/.aws/credentials
  else
    echo "Assigned Cloud9 instance profile is incorrect. Fix first and re-run."
    exit 1
  fi
else
  echo "Cloud9 role and caller identity correct..."
fi

# install tools
echo "Installing additional tools!"
echo "kubectl..."
curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f ./kubectl

echo "jq, getext, bash-completion, moreutils..."
sudo yum -y -q install jq gettext bash-completion moreutils
echo 'yq() {
  docker run --rm -i -v "${PWD}":/workdir mikefarah/yq "$@"
}' | tee -a ~/.bashrc && source ~/.bashrc

echo "eksctl..."
curl -sLO "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz"
tar xz -C /tmp -f "eksctl_$(uname -s)_amd64.tar.gz"
sudo install -o root -g root -m 0755 /tmp/eksctl /usr/local/bin/eksctl
rm -f ./"eksctl_$(uname -s)_amd64.tar.gz"

echo "aws-iam-authenticator..."
curl -sLO "https://amazon-eks.s3.us-west-2.amazonaws.com/1.19.6/2021-01-05/bin/linux/amd64/aws-iam-authenticator"
sudo install -o root -g root -m 0755 aws-iam-authenticator /usr/local/bin/aws-iam-authenticator
rm -f ./aws-iam-authenticator

echo "Install kind..."
curl -sLo kind "https://kind.sigs.k8s.io/dl/v0.11.0/kind-linux-amd64"
sudo install -o root -g root -m 0755 kind /usr/local/bin/kind
rm -f ./kind

echo "Helm..."
bash <(curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3)
helm repo add stable https://charts.helm.sh/stable
echo "Done with tools!"$'\n'

# tab completion
echo "Setting up tab completion.."$'\n'
/usr/local/bin/kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl >/dev/null
/usr/local/bin/eksctl completion bash | sudo tee /etc/bash_completion.d/eksctl >/dev/null
echo 'source /usr/share/bash-completion/bash_completion' >> $HOME/.bashrc

# Add env vars and put in bash profile
echo "Adding env vars..."$'\n'
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
export AZS=($(aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text --region $AWS_REGION))
echo "export ACCOUNT_ID=${ACCOUNT_ID}" | tee -a ~/.bash_profile
echo "export AWS_REGION=${AWS_REGION}" | tee -a ~/.bash_profile
echo "export AZS=(${AZS[@]})" | tee -a ~/.bash_profile
aws configure set default.region ${AWS_REGION}
aws configure get default.region

echo "export ACCOUNT_ID=${ACCOUNT_ID}" >> ~/.bashrc
echo "export AWS_REGION=${AWS_REGION}" >> ~/.bashrc
echo "export AZS=(${AZS[@]})" >> ~/.bashrc
# aws configure set default.region ${AWS_REGION}

# resize root EBS volume 
echo "Online resizing EBS volume..."$'\n'
bash <(curl -sL https://eksworkshop.com/intermediate/200_migrate_to_eks/resize-ebs.sh) 30

# bring in repos needed for workshop
echo "Cloning Service Repos..."$'\n'
cd ~/environment
git clone https://github.com/aws-containers/ecsdemo-frontend.git
git clone https://github.com/aws-containers/ecsdemo-nodejs.git
git clone https://github.com/aws-containers/ecsdemo-crystal.git

echo 'export LBC_VERSION="v2.3.0"' >>  ~/.bash_profile

echo "Running update-kubeconfig to configure the kubectl config"
aws eks update-kubeconfig --name eksworkshop-eksctl

# Export Stack variables
STACK_NAME=$(eksctl get nodegroup --cluster eksworkshop-eksctl -o json | jq -r '.[].StackName')
ROLE_NAME=$(aws cloudformation describe-stack-resources --stack-name $STACK_NAME | jq -r '.StackResources[] | select(.ResourceType=="AWS::IAM::Role") | .PhysicalResourceId')
echo "export ROLE_NAME=${ROLE_NAME}" | tee -a ~/.bash_profile

echo "Fix EKS Console access"
c9builder=$(aws cloud9 describe-environment-memberships --environment-id=$C9_PID | jq -r '.memberships[].userArn')
if echo ${c9builder} | grep -q user; then
	rolearn=${c9builder}
        echo Role ARN: ${rolearn}
elif echo ${c9builder} | grep -q assumed-role; then
        assumedrolename=$(echo ${c9builder} | awk -F/ '{print $(NF-1)}')
        rolearn=$(aws iam get-role --role-name ${assumedrolename} --query Role.Arn --output text) 
        echo Role ARN: ${rolearn}
fi

eksctl create iamidentitymapping --cluster eksworkshop-eksctl --arn ${rolearn} --group system:masters --username admin

echo "Create OIDC Provider"
eksctl utils associate-iam-oidc-provider --cluster eksworkshop-eksctl --approve

aws sts get-caller-identity --query Arn | grep eksworkshop-admin -q && echo "IAM role valid" || echo "IAM role NOT valid"

# report end and exit
echo "All Finished! Run 'source ~/.bashrc && source ~/.bash_profile' to finish!'"
exit 0
