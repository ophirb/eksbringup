export account_number=281138344795
export cluster_name=urithiru
export aws_region=us-east-1
export domain_name=simplecluster.com
export execution_folder=~/repos/eksbringup/cluster_handling


cd ${execution_folder}

#create the cluster
eksctl create cluster --name=${cluster_name} \
                      --region=${aws_region} \
                      --zones=${aws_region}a,${aws_region}b \
                      --version="1.24" \
                      --without-nodegroup 

# create nodegroup(s)
eksctl create nodegroup --cluster=${cluster_name} \
                        --region=${aws_region} \
                        --name=${cluster_name}-ng-private1 \
                        --node-type=t3.medium \
                        --nodes-min=2 \
                        --nodes-max=4 \
                        --node-volume-size=20 \
                        --ssh-access \
                        --ssh-public-key=urithiru_key \
                        --managed \
                        --asg-access \
                        --external-dns-access \
                        --full-ecr-access \
                        --appmesh-access \
                        --alb-ingress-access \
                        --node-private-networking       

# get the vpc id for several uses
export vpc_id=$(aws ec2 describe-vpcs --filter Name=tag:Name,Values=eksctl-${cluster_name}-cluster/VPC | jq -r '.Vpcs[].VpcId') 

# Create an OIDC provider and IAM role for the AWS Load Balancer Controller
eksctl utils associate-iam-oidc-provider \
    --region ${aws_region} \
    --cluster ${cluster_name} \
    --approve

# create a IAM policy and role for the load-balancer-contorller
curl -o iam_policy_latest.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
export alb_policy_arn=$(aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy_latest.json | jq -r '.Policy.Arn')
eksctl create iamserviceaccount \
  --cluster=${cluster_name} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=${alb_policy_arn} \
  --override-existing-serviceaccounts \
  --approve

# add a secret to the load-balancer-controller service account
kubectl apply -f ./manifests/lb/00-secrets/00-alb-secret.yaml

# add an IAM policy to your IAM role. The IAM policy gives the AWS Load Balancer Controller access to the resources created by the AWS ALB Ingress Controller for Kubernetes.
curl -o iam_policy_v1_to_v2_additional.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy_v1_to_v2_additional.json
export policy_addition_arn=$(aws iam create-policy --policy-name AWSLoadBalancerControllerAdditionalIAMPolicy --policy-document file://iam_policy_v1_to_v2_additional.json | jq -r '.Policy.Arn')
role_name=$(aws iam list-roles | jq -r '.Roles[].RoleName' | grep -i eksctl-urithiru-addon-iamserviceaccount-kube-Role)
aws iam attach-role-policy --role-name ${role_name}  --policy-arn ${policy_addition_arn}

# move files downloaded from the internet to .tmp folder
mkdir -p .tmp
mv iam_policy_* .tmp/

# Install the AWS Load Balancer Controller using Helm 3.0.0
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${cluster_name} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${aws_region} \
  --set vpcId=${vpc_id} \
  --set image.repository=602401143452.dkr.ecr.${aws_region}.amazonaws.com/amazon/aws-load-balancer-controller
#                          ^^^^^^ in case of using aws region different than us-east-1, 
#                                 we need to chech the correct account repo for this from: 
#                                 https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html

# create ingress controller class
kubectl apply -f  ./manifests/lb --recursive

# create domain certificate 
export certificate_arn=$(aws acm request-certificate \
--domain-name   "*.${domain_name}" \
--validation-method DNS | jq -r '.CertificateArn')

sleep 10 

# register the domain certificate arn in route53
export CNAME_name=$(aws acm describe-certificate --certificate-arn $certificate_arn | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord.Name')
export CNAME_value=$(aws acm describe-certificate --certificate-arn $certificate_arn | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord.Value')

hz_prefix="/hostedzone/"
hz_full=$(aws route53 list-hosted-zones-by-name --dns-name $domain_name | jq -r '.HostedZones[].Id')
export hosted_zone_id=${hz_full#"$hz_prefix"}                                                                            


aws route53 change-resource-record-sets \
  --hosted-zone-id ${hosted_zone_id} \
  --change-batch '
  {
    "Comment": "CName recordset for the certificate"
    ,"Changes": [{
      "Action"              : "CREATE"
      ,"ResourceRecordSet"  : {
        "Name"              : "'"${CNAME_name}"'"
        ,"Type"             : "CNAME"
        ,"TTL"              : 120
        ,"ResourceRecords"  : [{
            "Value"         : "'"${CNAME_value}"'"
        }]
      }
    }]
  }
  ' | jq '.'

# wait for the domain certificate to be ready
aws acm wait certificate-validated --certificate-arn $certificate_arn


# create a policy that will allow external-dns pod to add, remove DNS entries (Record Sets in a Hosted Zone) in AWS Route53 service
export ext_dns_policy_arn=$(aws iam create-policy --policy-name AllowExternalDNSUpdates --policy-document file://helper_files/AllowExternalDNSUpdates.json | jq -r '.Policy.Arn')
eksctl create iamserviceaccount \
  --cluster=${cluster_name} \
  --namespace=default \
  --name=external-dns \
  --attach-policy-arn=${ext_dns_policy_arn} \
  --override-existing-serviceaccounts \
  --approve

# add the external dns management deployment, with the relevant permissions
external_dns_role_arn_tmp=$(kubectl describe sa external-dns | grep -i Annotations:)
prefix="Annotations:         eks.amazonaws.com/role-arn: "
export external_dns_role_arn=${external_dns_role_arn_tmp#"$prefix"}
export external_dns_role_arn_escaped="${external_dns_role_arn//\//\\/}"
sed "s/eks.amazonaws.com\/role-arn: /eks.amazonaws.com\/role-arn: ${external_dns_role_arn_escaped}/g" manifests/external-dns/external-dns.template > manifests/external-dns/external-dns-${cluster_name}.yaml
kubectl apply -f ./manifests/external-dns/external-dns-${cluster_name}.yaml


# create internet facing ingress (with ssl-redirect and external dns support) for further use 
export certificate_arn_escaped="${certificate_arn//\//\\/}"
sed "s/alb.ingress.kubernetes.io\/certificate-arn: /alb.ingress.kubernetes.io\/certificate-arn: ${certificate_arn_escaped}/g" manifests/ingress/alb-ingress.template > manifests/ingress/alb-ingress-${cluster_name}.yaml
sed -i '' "s/external-dns.alpha.kubernetes.io\/hostname: /external-dns.alpha.kubernetes.io\/hostname: example1.${domain_name}, example2.${domain_name}/g" manifests/ingress/alb-ingress-${cluster_name}.yaml
kubectl apply -f ./manifests/ingress/alb-ingress-${cluster_name}.yaml


# create RDS in private subnet
# 1. find the vpc id
# 2. create a security group "Allow access for RDS Database on port 3306" (Name: eks_rds_db_sg) in our vpc
#   2.1 Type: MYSQL/Aurora
#   2.2 Proto: TCP
#   2.3 Port:  3306
#   2.4 Source: Anywhere
# 3. find the private subnets
# 4. Create DB subnet group
# 5. Free tier
# 6. DBName: usermgmtdb
# 7. User/Pass: dbadmin/dbpassword11
export rds_db_name="usermgmtdb"
export rds_db_instance_sz="db.t3.micro"
export rds_db_engine="mysql"
export rds_db_useradmin="dbadmin"
export rds_db_passadmin="dbpassword11"
export rds_db_alloc_storage=20
export rds_db_az="${aws_region}a"

# security group for rds
export rds_vpc_sec_gr=$(aws ec2 create-security-group \
                          --group-name eks_rds_db_sg \
                          --description "Allow access for RDS Database on port 3306" \
                          --vpc-id ${vpc_id} \
                          | jq -r '.GroupId')
retval=$(aws ec2 authorize-security-group-ingress \
    --group-id ${rds_vpc_sec_gr} \
    --protocol tcp \
    --port 3306 \
    --cidr 0.0.0.0/0 | jq -r '.Return')
if [[ $retval != true ]]; 
then 
  echo "Could not add rule to policy for RDS creation" 
  return
fi
aws ec2 authorize-security-group-ingress \
    --group-id ${rds_vpc_sec_gr} --protocol tcp --port 3306 | jq '.'

# subnet group for rds
export vpc_private_subnet_ids=$(aws ec2 describe-subnets --filter Name=vpc-id,Values=${vpc_id} --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId')
export rds_db_subnet=$(aws rds create-db-subnet-group \
    --db-subnet-group-name rds_subnet \
    --db-subnet-group-description "RDS subnet group" \
    --subnet-ids ${vpc_private_subnet_ids} | jq -r '.DBSubnetGroup.DBSubnetGroupName')

# actual creation of the rds
aws rds create-db-instance \
    --db-instance-identifier ${rds_db_name} \
    --db-instance-class ${rds_db_instance_sz} \
    --engine ${rds_db_engine} \
    --availability-zone ${rds_db_az} \
    --db-subnet-group-name ${rds_db_subnet} \
    --vpc-security-group-ids ${rds_vpc_sec_gr} \
    --master-username ${rds_db_useradmin} \
    --master-user-password ${rds_db_passadmin} \
    --allocated-storage ${rds_db_alloc_storage} | jq '.'

# wait for the rds to become available
aws rds wait db-instance-available --db-instance-identifier=usermgmtdb

# create a secret for the db (dbpassword11)
kubectl apply -f ./manifests/rds/secrets.yaml

# create an external name for the rds
export rds_endpoint=$(aws rds describe-db-instances --db-instance-identifier usermgmtdb | jq -r '.DBInstances[].Endpoint.Address')
sed "s/externalName: /externalName: ${rds_endpoint}/g" manifests/rds/external-name.template > manifests/rds/external-name-${cluster_name}.yaml
kubectl apply -f manifests/rds/external-name-${cluster_name}.yaml

