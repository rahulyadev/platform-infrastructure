locals {
  identity_image_contract     = jsondecode(file("${path.root}/../../../../config/runtime/identity-images.json"))
  identity_api_repository_url = "${var.expected_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.name_prefix}-identity-api"
  identity_bff_repository_url = "${var.expected_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.name_prefix}-identity-bff"

  identity_compose = templatefile("${path.root}/../../../../config/runtime/identity-compose.yml.tftpl", {
    postgres_image   = local.identity_image_contract.postgres.image
    redis_image      = local.identity_image_contract.redis.image
    pgbackrest_image = local.identity_image_contract.pgbackrest.image
    aws_region       = var.aws_region
    name_prefix      = local.name_prefix
  })

  identity_nginx = templatefile("${path.root}/../../../../config/nginx/identity-runtime.conf.tftpl", {
    base_domain = var.base_domain
  })

  identity_pgbackrest = templatefile("${path.root}/../../../../config/runtime/pgbackrest.conf.tftpl", {
    backup_bucket = local.core.backup_bucket_name
    aws_region    = var.aws_region
  })

  identity_document_scripts = {
    configure = templatefile("${path.root}/../../../../deploy/ssm/configure-identity-runtime.sh.tftpl", {
      docker_version         = local.identity_image_contract.docker.version
      docker_archive_sha256  = local.identity_image_contract.docker.archive_sha256
      compose_version        = local.identity_image_contract.compose.version
      compose_binary_sha256  = local.identity_image_contract.compose.binary_sha256
      pgbackrest_version     = local.identity_image_contract.pgbackrest.version
      pgbackrest_tar_sha256  = local.identity_image_contract.pgbackrest.tar_sha256
      compose_b64gzip        = base64gzip(local.identity_compose)
      nginx_b64gzip          = base64gzip(local.identity_nginx)
      pgbackrest_b64gzip     = base64gzip(local.identity_pgbackrest)
      systemd_unit_b64gzip   = base64gzip(file("${path.root}/../../../../config/runtime/identity-stack.service"))
      postgres_roles_b64gzip = base64gzip(file("${path.root}/../../../../config/runtime/postgres-roles.sql"))
      postgres_hba_b64gzip   = base64gzip(file("${path.root}/../../../../config/runtime/postgres-hba.conf"))
      launcher_b64gzip       = base64gzip(file("${path.root}/../../../../config/runtime/identity-launcher.py"))
      verify_release_b64gzip = base64gzip(replace(
        replace(
          file("${path.root}/../../../../deploy/ssm/verify-identity-release.sh"),
          "__IDENTITY_API_REPOSITORY_URL__",
          local.identity_api_repository_url
        ),
        "__IDENTITY_BFF_REPOSITORY_URL__",
        local.identity_bff_repository_url
      ))
      health_verify_b64gzip      = base64gzip(file("${path.root}/../../../../deploy/ssm/verify-identity.sh"))
      pgbackrest_sidecar_b64gzip = base64gzip(file("${path.root}/../../../../config/runtime/pgbackrest-sidecar.sh"))
      docker_service_b64gzip     = base64gzip(file("${path.root}/../../../../config/runtime/docker.service"))
      pgbackrest_passwd_b64gzip  = base64gzip(file("${path.root}/../../../../config/runtime/pgbackrest-passwd"))
      bff_client_secret_arn      = var.identity_bff_client_secret_arn == null ? "" : var.identity_bff_client_secret_arn
      database_secret_arn        = var.identity_database_secret_arn == null ? "" : var.identity_database_secret_arn
      redis_secret_arn           = var.identity_redis_secret_arn == null ? "" : var.identity_redis_secret_arn
      backup_secret_arn          = var.identity_backup_secret_arn == null ? "" : var.identity_backup_secret_arn
    })
    deploy   = file("${path.root}/../../../../deploy/ssm/deploy-identity.sh")
    tls      = file("${path.root}/../../../../deploy/ssm/enable-identity-tls.sh")
    verify   = file("${path.root}/../../../../deploy/ssm/verify-identity.sh")
    rollback = file("${path.root}/../../../../deploy/ssm/rollback-identity.sh")
    backup   = file("${path.root}/../../../../deploy/ssm/backup-identity.sh")
    restore  = file("${path.root}/../../../../deploy/ssm/restore-identity.sh")
  }
}

module "identity_production" {
  count  = var.enable_identity_delivery_foundation ? 1 : 0
  source = "../../../modules/identity_production"

  name_prefix              = local.name_prefix
  aws_region               = var.aws_region
  expected_account_id      = var.expected_account_id
  instance_id              = local.core.instance_id
  instance_role_name       = element(reverse(split("/", local.core.instance_role_arn)), 0)
  github_oidc_provider_arn = module.deployment.github_oidc_provider_arn
  github_owner             = var.identity_github_owner
  github_repository        = var.identity_github_repository
  github_owner_id          = var.identity_github_owner_id
  github_repository_id     = var.identity_github_repository_id
  github_environment       = var.identity_github_environment
  backup_bucket_arn        = local.core.backup_bucket_arn
  alarm_topic_arn          = module.monitoring.alarm_topic_arn
  runtime_secret_arns = toset([
    var.identity_bff_client_secret_arn,
    var.identity_database_secret_arn,
    var.identity_redis_secret_arn,
    var.identity_backup_secret_arn,
  ])
  enable_runtime   = var.enable_identity_production_runtime
  document_scripts = local.identity_document_scripts
  tags             = local.default_tags
}
