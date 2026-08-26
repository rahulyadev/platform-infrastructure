project_name       = "platform-infrastructure"
environment        = "production"
aws_region         = "ap-south-1"
base_domain        = "rahuly.in"
github_owner       = "rahulyadev"
github_repository  = "platform-infrastructure"
github_environment = "production"

log_retention_days = {
  nginx_access = 7
  nginx_error  = 30
  deployment   = 90
  system       = 30
}

runtime_package_versions = {
  nginx                   = "nginx-1:1.30.4-1.amzn2023.0.1.aarch64"
  aws_cli                 = "awscli-2-2.33.15-1.amzn2023.0.1.noarch"
  python                  = "python3.12-3.12.13-2.amzn2023.0.5.aarch64"
  python_libraries        = "python3.12-libs-3.12.13-2.amzn2023.0.5.aarch64"
  python_pip              = "python3.12-pip-23.2.1-4.amzn2023.0.10.noarch"
  python_pip_wheel        = "python3.12-pip-wheel-23.2.1-4.amzn2023.0.10.noarch"
  python_setuptools       = "python3.12-setuptools-68.2.2-4.amzn2023.0.3.noarch"
  python_setuptools_wheel = "python3.12-setuptools-wheel-68.2.2-4.amzn2023.0.3.noarch"
  python_wheel            = "python3.12-wheel-1:0.45.1-1.amzn2023.0.1.noarch"
  amazon_cloudwatch_agent = "1.300071.0b1720"
}

certbot_version                  = "5.7.0"
daily_snapshot_retention_count   = 7
monthly_snapshot_retention_count = 3

enable_identity_delivery_foundation = false
enable_identity_production_runtime  = false
identity_api_image                  = null
identity_bff_image                  = null
identity_api_image_platform         = null
identity_bff_image_platform         = null
identity_auth_certificate_arn       = null
identity_cognito_issuer             = null
identity_cognito_jwks_uri           = null
identity_cognito_audience           = null
identity_cognito_client_id          = null
identity_bff_origin                 = null
identity_redis_namespace            = "portfolio:identity:bff:"
identity_github_owner               = "rahulyadev"
identity_github_repository          = "identity-service"
identity_github_owner_id            = null
identity_github_repository_id       = null
identity_github_environment         = "production"
identity_bff_client_secret_arn      = null
identity_bff_runtime_secret_arn     = null
identity_database_secret_arn        = null
identity_redis_secret_arn           = null
identity_backup_secret_arn          = null
