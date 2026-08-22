locals {
  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.name_prefix}-status-check-failed"
  alarm_description   = "The production EC2 instance or system status check failed."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name_prefix}-cpu-high"
  alarm_description   = "CPU utilization is at least 80 percent for fifteen minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 80
  treat_missing_data  = "missing"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_credit_low" {
  alarm_name          = "${var.name_prefix}-cpu-credit-low"
  alarm_description   = "T4g CPU credit balance is low."
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 20
  treat_missing_data  = "missing"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_surplus_charged" {
  alarm_name          = "${var.name_prefix}-cpu-surplus-charged"
  alarm_description   = "Unlimited-mode T4g surplus CPU credits incurred charges."
  namespace           = "AWS/EC2"
  metric_name         = "CPUSurplusCreditsCharged"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.name_prefix}-memory-high"
  alarm_description   = "Host memory use is at least 85 percent."
  namespace           = var.metric_namespace
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 85
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "root_disk_high" {
  alarm_name          = "${var.name_prefix}-root-disk-high"
  alarm_description   = "Root filesystem use is at least 80 percent."
  namespace           = var.metric_namespace
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 80
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "root_inode_high" {
  alarm_name          = "${var.name_prefix}-root-inode-high"
  alarm_description   = "Root filesystem inode use is at least 80 percent."
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 80
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "inode_used_percent"
    expression  = "100 * inode_used / inode_total"
    label       = "Root filesystem inode use percent"
    return_data = true
  }

  metric_query {
    id          = "inode_used"
    return_data = false

    metric {
      metric_name = "disk_inodes_used"
      namespace   = var.metric_namespace
      period      = 300
      stat        = "Maximum"
      dimensions  = { InstanceId = var.instance_id }
    }
  }

  metric_query {
    id          = "inode_total"
    return_data = false

    metric {
      metric_name = "disk_inodes_total"
      namespace   = var.metric_namespace
      period      = 300
      stat        = "Minimum"
      dimensions  = { InstanceId = var.instance_id }
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "nginx_process_absent" {
  alarm_name          = "${var.name_prefix}-nginx-process-absent"
  alarm_description   = "The CloudWatch Agent cannot observe an Nginx master process."
  namespace           = var.metric_namespace
  metric_name         = "procstat_lookup_pid_count"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { InstanceId = var.instance_id }
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = var.tags
}
