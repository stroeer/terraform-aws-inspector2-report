locals {
  bucket_name = var.bucket_arn != null ? provider::aws::arn_parse(var.bucket_arn)["resource"] : var.bucket_name
  prefix      = "security-services"
}

module "destination_bucket" {
  count   = var.bucket_arn == null ? 1 : 0
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "4.1.2"

  bucket        = var.bucket_name
  acl           = "private"
  force_destroy = true

  attach_policy                            = true
  attach_deny_insecure_transport_policy    = true
  attach_require_latest_tls_policy         = true
  attach_deny_incorrect_encryption_headers = true
  attach_deny_incorrect_kms_key_sse        = true
  attach_deny_unencrypted_object_uploads   = true


  lifecycle_rule = [
    {
      id      = "expire-previous-versions"
      enabled = true

      noncurrent_version_expiration = {
        days = 30
      }
    }
  ]
  versioning = {
    enabled = true
  }
}
