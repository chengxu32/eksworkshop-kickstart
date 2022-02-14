#!/bin/bash

set -e

# check that role is correct before proceeding
rm -vf ${HOME}/.aws/credentials
echo "Checking Cloud9 IAM Role = eksworkshop-admin..."
if aws sts get-caller-identity --query Arn | grep eksworkshop-admin ; then
  echo "Correct role detected."
else
    echo "Cloud9 IAM Role incorrect. Fix and re-run"
    exit 1
fi

# install tools
echo "Installing tools!"
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

echo "awscliv2..."
curl -sLo "awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf ./awscliv2.zip ./aws

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
echo "export ACCOUNT_ID=${ACCOUNT_ID}" >> ~/.bash_profile
echo "export AWS_REGION=${AWS_REGION}" >> ~/.bash_profile
aws configure set default.region ${AWS_REGION}

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

echo "Fix Console access"
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

# report end and exit
echo "All Finished! Run following commands before continue..."
echo "Run 'source ~/.bashrc' "
echo "Run 'source ~/.bash_profile' "
exit 0
