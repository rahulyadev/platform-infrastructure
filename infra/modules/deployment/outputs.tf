output "configure_runtime_document_name" {
  description = "Fixed runtime-configuration SSM document name."
  value       = aws_ssm_document.configure_runtime.name
}

output "deploy_portfolio_document_name" {
  description = "Fixed portfolio-deployment SSM document name."
  value       = aws_ssm_document.deploy_portfolio.name
}

output "rollback_portfolio_document_name" {
  description = "Fixed portfolio-rollback SSM document name."
  value       = aws_ssm_document.rollback_portfolio.name
}

output "enable_tls_document_name" {
  description = "Fixed TLS-enablement SSM document name."
  value       = aws_ssm_document.enable_tls.name
}

output "github_deployment_role_arn" {
  description = "GitHub OIDC deployment role ARN."
  value       = aws_iam_role.github_deployer.arn
}

output "github_subject" {
  description = "Exact immutable GitHub OIDC subject claim."
  value       = local.github_subject
}
