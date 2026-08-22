output "alarm_topic_arn" {
  description = "SNS topic used for alarm and recovery notifications."
  value       = aws_sns_topic.alarms.arn
}

output "subscription_pending_confirmation" {
  description = "Pending-confirmation state by alert email endpoint."
  value = {
    for endpoint, subscription in aws_sns_topic_subscription.email :
    endpoint => subscription.pending_confirmation
  }
}

output "log_group_names" {
  description = "Exact runtime log group names."
  value       = { for key, group in aws_cloudwatch_log_group.runtime : key => group.name }
}

output "cloudwatch_agent_parameter_name" {
  description = "SSM Parameter containing the non-secret CloudWatch Agent configuration."
  value       = aws_ssm_parameter.cloudwatch_agent.name
}
