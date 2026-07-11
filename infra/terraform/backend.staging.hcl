# Partial backend config for staging state on DigitalOcean Spaces (S3-compatible).
# Non-secret: the Spaces access keys are passed as AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY env vars at `terraform init` (GH Actions secrets in CI).
# Used as: terraform init -backend-config=backend.staging.hcl
bucket = "zimmer-tfstate"
key    = "staging/terraform.tfstate"
region = "us-east-1" # Spaces ignores this, but the S3 backend requires a value.

endpoints = {
  s3 = "https://nyc3.digitaloceanspaces.com"
}

# DO Spaces is S3-compatible but not AWS: skip the AWS-specific preflight calls,
# and use S3-native state locking (Terraform >= 1.10) since Spaces has no DynamoDB.
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_s3_checksum            = true
use_lockfile                = true
