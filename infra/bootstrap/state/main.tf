locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Repository  = "rahulyadev/platform-infrastructure"
  }

  bucket_name = "${var.project_name}-${var.expected_account_id}-${var.aws_region}-${var.state_suffix}"
}

module "state_bucket" {
  source = "../../modules/private_versioned_bucket"

  bucket_name                        = local.bucket_name
  noncurrent_version_expiration_days = var.noncurrent_version_expiration_days
  tags                               = local.default_tags
}
