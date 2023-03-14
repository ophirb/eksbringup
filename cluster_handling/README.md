Creates a basic cluster
    1. single node group in the private subnet
    2. ingress object to handle alb

For the certificate handling:
1. Register a domain in AWS at https://us-east-1.console.aws.amazon.com/route53/home#DomainRegistration:
2. execute the bash script. It will do the entire boilertape work for you. It will create a new certificate, and approve it in route53 DNS.
3. INPUT: just supply the domain name registered in bullet #1 at the beginning of the file
