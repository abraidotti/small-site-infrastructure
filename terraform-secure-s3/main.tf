#
# https://docs.aws.amazon.com/AmazonS3/latest/dev/website-hosting-custom-domain-walkthrough.html
# https://docs.aws.amazon.com/AmazonS3/latest/dev/website-hosting-cloudfront-walkthrough.html
# https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html
# https://aws.amazon.com/blogs/networking-and-content-delivery/adding-http-security-headers-using-lambdaedge-and-amazon-cloudfront/
#

provider "aws" {
  # ACM cert validataion and Lambda@Edge creation can only happen in us-east-1
  alias  = "virginia"
  region = "us-east-1"
}

data "aws_route53_zone" "main" {
  name         = var.root
  private_zone = false
}

## ACM (AWS Certificate Manager)
# Creates the wildcard certificate *.<yourdomain.com>
resource "aws_acm_certificate" "cert" {
  provider = aws.virginia

  domain_name               = var.root
  subject_alternative_names = ["*.${var.root}"]
  validation_method         = "DNS"

  tags = {
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_route53_record" "wildcard_validation" {
  name    = aws_acm_certificate.cert.domain_validation_options[0].resource_record_name
  records = [aws_acm_certificate.cert.domain_validation_options[0].resource_record_value]
  ttl     = "60"
  type    = aws_acm_certificate.cert.domain_validation_options[0].resource_record_type
  zone_id = data.aws_route53_zone.main.zone_id
}

# Triggers the ACM wildcard certificate validation event
resource "aws_acm_certificate_validation" "wildcard_cert" {
  provider = aws.virginia

  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [aws_route53_record.wildcard_validation.fqdn]
}

# Get the ARN of the issued certificate
data "aws_acm_certificate" "cert" {
  provider = aws.virginia

  domain      = var.root
  most_recent = true
  statuses    = ["ISSUED"]

  depends_on = [
    aws_acm_certificate.cert,
    aws_route53_record.wildcard_validation,
    aws_acm_certificate_validation.wildcard_cert,
  ]
}

resource "aws_s3_bucket" "logs" {
  acl           = "log-delivery-write"
  bucket        = "${var.root}-logs"
  force_destroy = true

  tags = {
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_s3_bucket" "root" {
  bucket        = var.root
  force_destroy = true

  logging {
    target_bucket = aws_s3_bucket.logs.bucket
    target_prefix = "${var.root}/"
  }

  website {
    error_document = "index.html"
    index_document = "index.html"
  }

  tags = {
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_cloudfront_origin_access_identity" "oai_root" {
  comment = "CloudfrontOriginAccessIdentity - ${var.root}"
}

resource "aws_cloudfront_distribution" "website_cdn_root" {
  aliases             = [var.root, var.redirect]
  default_root_object = "index.html"
  enabled             = true

  # See https://aws.amazon.com/cloudfront/pricing/
  #price_class = "PriceClass_All"
  #price_class = "PriceClass_200"
  price_class = "PriceClass_100"

  origin {
    domain_name = aws_s3_bucket.root.bucket_regional_domain_name
    origin_id   = "origin-bucket-${aws_s3_bucket.root.id}"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai_root.cloudfront_access_identity_path
    }
  }


  logging_config {
    bucket = aws_s3_bucket.logs.bucket_domain_name
    prefix = "${var.root}/"
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    default_ttl            = "300"
    max_ttl                = "1200"
    min_ttl                = "0"
    target_origin_id       = "origin-bucket-${aws_s3_bucket.root.id}"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    lambda_function_association {
      event_type = "origin-response"
      lambda_arn = aws_lambda_function.add_http_security_headers.qualified_arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.cert.arn
    minimum_protocol_version = "TLSv1.2_2019"
    ssl_support_method       = "sni-only"
  }

  custom_error_response {
    error_caching_min_ttl = 300
    error_code            = 404
    response_code         = 404
    response_page_path    = "/index.html"
  }

  tags = {
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [
      tags,
      viewer_certificate,
    ]
  }
}

resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.root
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website_cdn_root.domain_name
    zone_id                = aws_cloudfront_distribution.website_cdn_root.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "redirect" {
  name    = var.redirect
  records = [var.root]
  ttl     = 5
  type    = "CNAME"
  zone_id = data.aws_route53_zone.main.zone_id
}

resource "aws_s3_bucket_policy" "root_bucket_policy" {
  bucket = aws_s3_bucket.root.id

  policy = <<-EOF
    {
      "Version": "2008-10-17",
      "Id": "PolicyForCloudFrontPrivateContent",
      "Statement": [
        {
          "Sid": "AllowCloudFrontOriginAccess",
          "Effect": "Allow",
          "Principal": {
            "AWS": "${aws_cloudfront_origin_access_identity.oai_root.iam_arn}"
          },
          "Action": [
            "s3:GetObject",
            "s3:ListBucket"
          ],
          "Resource": [
            "${aws_s3_bucket.root.arn}/*",
            "${aws_s3_bucket.root.arn}"
          ]
        }
      ]
    }
    EOF
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}

# Create the IAM role that will be attached to the Lambda Function and associate it with the previously created policy
resource "aws_iam_role" "lambda_assume_role" {
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
  name               = "LambdaAssumeRole"
  path               = "/services-roles/"

  tags = {
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

# Attach the predefined AWSLambdaBasicExecutionRole to grant permission to the Lambda execution role to see the CloudWatch logs generated when CloudFront triggers the function.
resource "aws_iam_role_policy_attachment" "lambda_exec_role_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_assume_role.name
}

# Generates a ZIP archive from the Javascript script
data "archive_file" "add_http_security_headers" {
  output_path = "${path.module}/lambda/add_http_security_headers.js.zip"
  source_file = "${path.module}/lambda/add_http_security_headers.js"
  type        = "zip"
}

# Creates the Lambda Function
resource "aws_lambda_function" "add_http_security_headers" {
  provider         = aws.virginia

  description      = "Adds additional HTTP security headers to the origin-response"
  filename         = data.archive_file.add_http_security_headers.output_path
  function_name    = "add_http_security_headers"
  handler          = "add_http_security_headers.handler"
  publish          = true
  role             = aws_iam_role.lambda_assume_role.arn
  runtime          = "nodejs10.x"
  source_code_hash = data.archive_file.add_http_security_headers.output_base64sha256
  timeout          = "30" # 30 seconds is the MAXIMUM allowed for functions triggered by a CloudFront event

  tags = {
    Changed   = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}
