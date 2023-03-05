export account_number=281138344795
export cluster_name=urithiru
export aws_region=us-east-1
export domain_name=simplecluster.com


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
export vpc_id=$(aws ec2 describe-vpcs --filter Name=tag:Name,Values=eksctl-${cluster_name}-cluster/VPC | jq -r '.Vpcs[].VpcId') 
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
kubectl apply -f ./manifests/lb


# create certificate 
export certificate_arn=$(aws acm request-certificate \
--domain-name   "*.${domain_name}" \
--validation-method DNS | jq -r '.CertificateArn')

sleep 10 

# register the certificate arn in route53
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
  '

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

