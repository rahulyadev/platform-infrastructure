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

  enable_identity_authentication_module = anytrue([
    var.enable_identity_auth_certificate,
    var.enable_identity_auth_certificate_validation,
    var.enable_identity_google_federation,
    var.enable_identity_auth_domain,
  ])
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

module "identity_cognito_reference_bff_client" {
  count  = var.enable_identity_reference_bff_client ? 1 : 0
  source = "../../../modules/identity_cognito_reference_bff_client"

  user_pool_id                   = one(module.identity_cognito_core[*].user_pool_id)
  profile_read_scope_identifier  = one(module.identity_cognito_core[*].profile_read_scope_identifier)
  profile_write_scope_identifier = one(module.identity_cognito_core[*].profile_write_scope_identifier)
  name_prefix                    = local.name_prefix
  application_origins            = var.identity_reference_bff_application_origins

  depends_on = [module.identity_authentication]
}

module "identity_authentication" {
  count  = local.enable_identity_authentication_module ? 1 : 0
  source = "../../../modules/identity_authentication"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix                         = local.name_prefix
  auth_domain                         = local.domains.auth
  user_pool_id                        = var.enable_identity_cognito_core ? module.identity_cognito_core[0].user_pool_id : null
  enable_certificate_request          = var.enable_identity_auth_certificate
  enable_certificate_validation       = var.enable_identity_auth_certificate_validation
  certificate_validation_record_fqdns = var.identity_auth_certificate_validation_record_fqdns
  enable_google_federation            = var.enable_identity_google_federation
  google_credentials_secret_arn       = var.identity_google_credentials_secret_arn
  enable_user_pool_domain             = var.enable_identity_auth_domain
  tags                                = local.default_tags
}

module "identity_client_secret_custody" {
  count  = var.enable_identity_client_secret_custody ? 1 : 0
  source = "../../../modules/identity_secret_custody"

  name_prefix   = local.name_prefix
  client_secret = module.identity_cognito_reference_bff_client[0].client_secret
  tags          = local.default_tags
}
