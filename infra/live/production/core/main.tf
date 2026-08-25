data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Repository  = "rahulyadev/platform-infrastructure"
  }

  name_prefix          = "${var.project_name}-${var.environment}"
  account_name_prefix  = "${var.project_name}-${var.expected_account_id}-${var.aws_region}"
  artifact_bucket_name = "${local.account_name_prefix}-artifacts"
  backup_bucket_name   = "${local.account_name_prefix}-backups"

  domains = {
    portfolio = var.base_domain
    www       = "www.${var.base_domain}"
    auth      = "auth.${var.base_domain}"
    identity  = "identity.${var.base_domain}"
  }
}

module "artifact_bucket" {
  source = "../../../modules/private_versioned_bucket"

  bucket_name                        = local.artifact_bucket_name
  noncurrent_version_expiration_days = 365
  tags                               = local.default_tags
}

module "backup_bucket" {
  source = "../../../modules/private_versioned_bucket"

  bucket_name                        = local.backup_bucket_name
  noncurrent_version_expiration_days = 365
  tags                               = local.default_tags
}

module "network" {
  source = "../../../modules/network"

  name_prefix        = local.name_prefix
  availability_zone  = var.availability_zone
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
  tags               = local.default_tags
}

module "host" {
  source = "../../../modules/host"

  name_prefix              = local.name_prefix
  ami_id                   = data.aws_ssm_parameter.al2023_arm64.value
  instance_type            = var.instance_type
  subnet_id                = module.network.public_subnet_id
  security_group_id        = module.network.edge_security_group_id
  artifact_bucket_arn      = module.artifact_bucket.bucket_arn
  root_volume_size_gib     = var.root_volume_size_gib
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.default_tags
}

module "identity_cognito_core" {
  count  = var.enable_identity_cognito_core ? 1 : 0
  source = "../../../modules/identity_cognito_core"

  name_prefix = local.name_prefix
  tags        = local.default_tags
}
