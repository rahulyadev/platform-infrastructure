locals {
  identity_log_groups = toset([
    "api",
    "bff",
    "database",
    "deployment",
    "backup",
  ])

  identity_alarms = {
    api_health         = "IdentityApiHealthFailure"
    bff_health         = "IdentityBffHealthFailure"
    postgres_reachable = "IdentityPostgresReachabilityFailure"
    redis_reachable    = "IdentityRedisReachabilityFailure"
    container_restart  = "IdentityContainerRestart"
    container_failure  = "IdentityContainerFailure"
    memory_pressure    = "IdentityMemoryPressure"
    disk_pressure      = "IdentityDiskPressure"
    migration_failed   = "IdentityMigrationFailure"
    backup_stale       = "IdentityBackupStale"
    wal_stale          = "IdentityWalArchiveStale"
    deployment_failed  = "IdentityDeploymentFailure"
    certificate_expiry = "IdentityCertificateExpiry"
  }
}

resource "aws_cloudwatch_log_group" "identity" {
  for_each = local.identity_log_groups

  name              = "/${var.name_prefix}/identity/${each.value}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "identity" {
  for_each = local.identity_alarms

  alarm_name          = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  alarm_description   = "Identity production recovery signal: ${each.value}."
  namespace           = "PlatformInfrastructure/Production/Identity"
  metric_name         = each.value
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.instance_id
  }

  tags = var.tags
}
