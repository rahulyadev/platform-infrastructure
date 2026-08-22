locals {
  log_groups = {
    nginx_access = {
      name      = "/platform-infrastructure/production/nginx/access"
      retention = var.log_retention_days.nginx_access
    }
    nginx_error = {
      name      = "/platform-infrastructure/production/nginx/error"
      retention = var.log_retention_days.nginx_error
    }
    deployment = {
      name      = "/platform-infrastructure/production/deployment"
      retention = var.log_retention_days.deployment
    }
    system = {
      name      = "/platform-infrastructure/production/system"
      retention = var.log_retention_days.system
    }
  }
}

resource "aws_cloudwatch_log_group" "runtime" {
  for_each = local.log_groups

  name              = each.value.name
  retention_in_days = each.value.retention

  tags = var.tags
}

resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"

  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.alert_email_addresses

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}
