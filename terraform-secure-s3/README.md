# kintyre-runway-infrastructure

This script will set up an S3 bucket to host a web app on a given domain.

Example: run this script, and then sync your React app build directory with your new S3 bucket.

## Requirements

- [Terraform CLI](https://learn.hashicorp.com/tutorials/terraform/install-cli)

- [AWS CLI](https://aws.amazon.com/cli/)

- an AWS Hosted Zone (including a Route 53 domain name)

## Good to know

### CNAMEs and redirect buckets

This uses a CNAME alias instead of a 2nd bucket to redirect the requests.

### Certificate limits

ACM certificates can only be recreated 20 times. Otherwise, you'll need to recreate them.

It's best to update these terraform deployments, not apply and destroy.

## Operation

### Setup

Edit `terraform.tfvars.example` to `terraform.tfvars` and include your root domain name and redirect.

The root domain MUST be identical to a Hosted Zone in your AWS account, including its NS and SOA records.

```bash
cd terraform-secure-s3
terraform init
terraform apply
```

You will be prompted to supply an AWS profile.

Running this will take a while due to domain name validation, cloudfront distribution, and content replication. It will also create an S3 bucket for website access and error logs.

### Removal

```bash
cd terraform-secure-s3
terraform destroy
```

note: you won't be able to immediately destroy the lambdas.

You'll get an error like this:

```bash
Error: Error deleting Lambda Function: InvalidParameterValueException: Lambda was unable to delete arn:aws:lambda:us-east-1:XXX:function:add_http_security_headers:1 because it is a replicated function. Please see our documentation for Deleting Lambda@Edge Functions and Replicas.
{
  RespMetadata: {
    StatusCode: 400,
    RequestID: "XXX"
  },
  Message_: "Lambda was unable to delete arn:aws:lambda:us-east-1:XXX:function:add_http_security_headers:1 because it is a replicated function. Please see our documentation for Deleting Lambda@Edge Functions and Replicas."
}
```

According to [AWS documentation](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/lambda-edge-delete-replicas.html), the lambda will be deleted "within a few hours."

But you can also try waiting an hour or and running `terraform destroy` again.
