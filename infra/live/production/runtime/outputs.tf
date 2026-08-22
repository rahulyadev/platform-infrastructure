output "alarm_topic_arn" {
  description = "SNS topic used by runtime alarms."
  value       = module.monitoring.alarm_topic_arn
}

output "alarm_subscription_pending_confirmation" {
  description = "Whether each email endpoint still requires SNS confirmation."
  value       = module.monitoring.subscription_pending_confirmation
}

output "configure_runtime_document_name" {
  description = "Fixed SSM document that configures the host runtime."
  value       = module.deployment.configure_runtime_document_name
}

output "deploy_portfolio_document_name" {
  description = "Fixed SSM document used for immutable portfolio deployment."
  value       = module.deployment.deploy_portfolio_document_name
}

output "rollback_portfolio_document_name" {
  description = "Fixed SSM document used for explicit portfolio rollback."
  value       = module.deployment.rollback_portfolio_document_name
}

output "enable_tls_document_name" {
  description = "Fixed SSM document used after the DNS cutover gate to issue and enable TLS."
  value       = module.deployment.enable_tls_document_name
}

output "github_deployment_role_arn" {
  description = "Short-lived GitHub OIDC deployment role ARN."
  value       = module.deployment.github_deployment_role_arn
}

output "snapshot_policy_id" {
  description = "DLM lifecycle policy identifier."
  value       = module.snapshot_policy.policy_id
}
