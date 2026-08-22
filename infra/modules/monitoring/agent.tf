data "aws_iam_policy_document" "telemetry" {
  statement {
    sid       = "PublishRuntimeMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }

  statement {
    sid    = "WriteExactRuntimeLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      for group in values(aws_cloudwatch_log_group.runtime) : "${group.arn}:*"
    ]
  }

  statement {
    sid       = "ReadInstanceTags"
    effect    = "Allow"
    actions   = ["ec2:DescribeTags"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "telemetry" {
  name   = "${var.name_prefix}-telemetry"
  role   = var.instance_role_name
  policy = data.aws_iam_policy_document.telemetry.json
}

resource "aws_ssm_parameter" "cloudwatch_agent" {
  name        = "/${var.name_prefix}/cloudwatch-agent/config"
  description = "Non-secret production CloudWatch Agent configuration."
  type        = "String"
  data_type   = "text"
  tier        = "Standard"
  value       = var.cloudwatch_agent_config

  tags = var.tags
}

resource "aws_ssm_association" "install_cloudwatch_agent" {
  name             = "AWS-ConfigureAWSPackage"
  association_name = "${var.name_prefix}-install-cloudwatch-agent"

  parameters = {
    action  = "Install"
    name    = "AmazonCloudWatchAgent"
    version = var.cloudwatch_agent_version
  }

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }

  wait_for_success_timeout_seconds = 600

  tags = var.tags
}

resource "aws_ssm_association" "configure_cloudwatch_agent" {
  name             = "AmazonCloudWatch-ManageAgent"
  association_name = "${var.name_prefix}-configure-cloudwatch-agent"

  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cloudwatch_agent.name
    optionalRestart               = "yes"
  }

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }

  wait_for_success_timeout_seconds = 600

  tags = var.tags

  depends_on = [aws_ssm_association.install_cloudwatch_agent]
}
