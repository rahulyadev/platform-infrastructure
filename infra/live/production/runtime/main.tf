locals {
  name_prefix       = "${var.project_name}-${var.environment}"
  state_bucket_name = "${var.project_name}-${var.expected_account_id}-${var.aws_region}-state"
  metric_namespace  = "PlatformInfrastructure/Production"

  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Repository  = "${var.github_owner}/${var.github_repository}"
  }
}

data "terraform_remote_state" "core" {
  backend = "s3"

  config = {
    bucket              = local.state_bucket_name
    key                 = "production/core/tofu.tfstate"
    region              = var.aws_region
    allowed_account_ids = [var.expected_account_id]
    encrypt             = true
    use_lockfile        = true
  }
}

locals {
  core = {
    domains               = data.terraform_remote_state.core.outputs.domains
    artifact_bucket_name  = data.terraform_remote_state.core.outputs.artifact_bucket_name
    artifact_bucket_arn   = data.terraform_remote_state.core.outputs.artifact_bucket_arn
    backup_bucket_name    = data.terraform_remote_state.core.outputs.backup_bucket_name
    backup_bucket_arn     = data.terraform_remote_state.core.outputs.backup_bucket_arn
    instance_id           = data.terraform_remote_state.core.outputs.instance_id
    instance_arn          = data.terraform_remote_state.core.outputs.instance_arn
    elastic_ip            = data.terraform_remote_state.core.outputs.elastic_ip
    instance_role_arn     = data.terraform_remote_state.core.outputs.instance_role_arn
    instance_profile_name = data.terraform_remote_state.core.outputs.instance_profile_name
    root_volume_id        = data.terraform_remote_state.core.outputs.root_volume_id
  }

  cloudwatch_agent_config = templatefile("${path.root}/../../../../config/cloudwatch/agent-config.json.tftpl", {
    metric_namespace       = local.metric_namespace
    nginx_access_log_group = "/${var.project_name}/${var.environment}/nginx/access"
    nginx_error_log_group  = "/${var.project_name}/${var.environment}/nginx/error"
    deployment_log_group   = "/${var.project_name}/${var.environment}/deployment"
    system_log_group       = "/${var.project_name}/${var.environment}/system"
  })

  nginx_http_config = templatefile("${path.root}/../../../../config/nginx/portfolio-http.conf.tftpl", {
    base_domain = var.base_domain
    elastic_ip  = local.core.elastic_ip
  })

  nginx_tls_config = templatefile("${path.root}/../../../../config/nginx/portfolio-tls.conf.tftpl", {
    base_domain = var.base_domain
  })

  configure_runtime_script = templatefile("${path.root}/../../../../deploy/ssm/configure-runtime.sh.tftpl", {
    nginx_package                   = var.runtime_package_versions.nginx
    aws_cli_package                 = var.runtime_package_versions.aws_cli
    python_package                  = var.runtime_package_versions.python
    python_libraries_package        = var.runtime_package_versions.python_libraries
    python_pip_package              = var.runtime_package_versions.python_pip
    python_pip_wheel_package        = var.runtime_package_versions.python_pip_wheel
    python_setuptools_package       = var.runtime_package_versions.python_setuptools
    python_setuptools_wheel_package = var.runtime_package_versions.python_setuptools_wheel
    python_wheel_package            = var.runtime_package_versions.python_wheel
    certbot_version                 = var.certbot_version
    nginx_conf_b64                  = base64encode(file("${path.root}/../../../../config/nginx/nginx.conf"))
    http_conf_b64                   = base64encode(local.nginx_http_config)
    security_headers_b64            = base64encode(file("${path.root}/../../../../config/nginx/security-headers.conf"))
    smoke_script_b64                = base64encode(file("${path.root}/../../../../deploy/smoke-portfolio.sh"))
  })

  enable_tls_script = templatefile("${path.root}/../../../../deploy/ssm/enable-tls.sh.tftpl", {
    configured_base_domain = var.base_domain
    tls_conf_b64           = base64encode(local.nginx_tls_config)
  })
}

module "monitoring" {
  source = "../../../modules/monitoring"

  name_prefix              = local.name_prefix
  aws_region               = var.aws_region
  instance_id              = local.core.instance_id
  instance_role_name       = element(reverse(split("/", local.core.instance_role_arn)), 0)
  alert_email_addresses    = var.alert_email_addresses
  log_retention_days       = var.log_retention_days
  metric_namespace         = local.metric_namespace
  cloudwatch_agent_config  = local.cloudwatch_agent_config
  cloudwatch_agent_version = var.runtime_package_versions.amazon_cloudwatch_agent
  tags                     = local.default_tags
}

module "snapshot_policy" {
  source = "../../../modules/snapshot_policy"

  name_prefix = local.name_prefix
  target_instance_tags = {
    Project     = var.project_name
    Environment = var.environment
    Name        = "${local.name_prefix}-host"
  }
  daily_snapshot_retention_count   = var.daily_snapshot_retention_count
  monthly_snapshot_retention_count = var.monthly_snapshot_retention_count
  tags                             = local.default_tags
}

module "deployment" {
  source = "../../../modules/deployment"

  name_prefix               = local.name_prefix
  aws_region                = var.aws_region
  expected_account_id       = var.expected_account_id
  instance_id               = local.core.instance_id
  instance_arn              = local.core.instance_arn
  artifact_bucket_name      = local.core.artifact_bucket_name
  artifact_bucket_arn       = local.core.artifact_bucket_arn
  github_owner              = var.github_owner
  github_repository         = var.github_repository
  github_owner_id           = var.github_owner_id
  github_repository_id      = var.github_repository_id
  github_environment        = var.github_environment
  configure_runtime_script  = local.configure_runtime_script
  deploy_portfolio_script   = file("${path.root}/../../../../deploy/ssm/deploy-portfolio.sh")
  rollback_portfolio_script = file("${path.root}/../../../../deploy/ssm/rollback-portfolio.sh")
  enable_tls_script         = local.enable_tls_script
  base_domain               = var.base_domain
  expected_elastic_ip       = local.core.elastic_ip
  tags                      = local.default_tags
}
