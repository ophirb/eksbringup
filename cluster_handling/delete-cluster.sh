export account_number=281138344795
export cluster_name=urithiru
export aws_region=us-east-1
export domain_name=simplecluster.com
export rds_db_name="usermgmtdb"
export execution_folder=~/repos/eksbringup/cluster_handling


cd ${execution_folder}

# remove ingress object 
kubectl delete -f ./manifests/ingress/alb-ingress-${cluster_name}.yaml

# remove rds
aws rds delete-db-instance \
    --db-instance-identifier ${rds_db_name} \
    --skip-final-snapshot | jq '.'

# wait for the rds to be deleted
aws rds wait db-instance-deleted --db-instance-identifier=usermgmtdb

# remove rds subnet group
aws rds delete-db-subnet-group --db-subnet-group-name rds_subnet 

# remove route53 entries
export certificate_arn=$(aws acm list-certificates | jq -r '.CertificateSummaryList[] | select(.DomainName|match("/*.simplecluster.com")) | .CertificateArn')
export CNAME_name=$(aws acm describe-certificate --certificate-arn=${certificate_arn} | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord.Name')
export CNAME_value=$(aws acm describe-certificate --certificate-arn=${certificate_arn} | jq -r '.Certificate.DomainValidationOptions[].ResourceRecord.Value')
aws route53 change-resource-record-sets \
  --hosted-zone-id ${hosted_zone_id} \
  --change-batch '
  {
    "Comment": "CName recordset for the certificate"
    ,"Changes": [{
      "Action"              : "DELETE"
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


# remove service accounts (removes iam policies and iam roles)
eksctl delete iamserviceaccount \
  --cluster=${cluster_name} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller    

eksctl delete iamserviceaccount \
  --cluster=${cluster_name} \
  --namespace=default \
  --name=external-dns \


# detach iam policy <-> role
role_name=$(aws iam list-roles | jq -r '.Roles[].RoleName' | grep -i eksctl-urithiru-addon-iamserviceaccount-kube-Role)
policy_addition_arn=arn:aws:iam::${account_number}:policy/AWSLoadBalancerControllerAdditionalIAMPolicy
aws iam detach-role-policy --role-name ${role_name}  --policy-arn ${policy_addition_arn}
aws iam delete-policy --policy-arn arn:aws:iam::${account_number}:policy/AWSLoadBalancerControllerAdditionalIAMPolicy

aws iam delete-policy --policy-arn arn:aws:iam::${account_number}:policy/AWSLoadBalancerControllerIAMPolicy

aws iam delete-policy --policy-arn arn:aws:iam::${account_number}:policy/AllowExternalDNSUpdates

eksctl delete cluster ${cluster_name}

# remove certificate
aws acm delete-certificate --certificate-arn ${certificate_arn}







# NOT NEEDED
# # remove iam policies
# # AllowExternalDNSUpdates
# # AWSLoadBalancerControllerAdditionalIAMPolicy
# # AWSLoadBalancerControllerIAMPolicy
# aws iam delete-policy --policy-arn arn:aws:iam::${account_number}:policy/AllowExternalDNSUpdates
# aws iam delete-policy --policy-arn arn:aws:iam::${account_number}:policy/AWSLoadBalancerControllerIAMPolicy


# # remove iam roles
# export list_roles=$(aws iam list-roles | jq -r '.Roles[] | select(.RoleName|match("eksctl")) | .RoleName')
# for str in ${list_roles[@]}; do
#   aws iam delete-role --role-name ${str}
# done
