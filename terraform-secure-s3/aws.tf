provider "aws" {
  region = "us-east-1"
  version = "~> 2.70"
  profile = var.aws_profile
}
