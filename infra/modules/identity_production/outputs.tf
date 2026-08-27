output "repository_urls" {
  description = "Non-secret immutable ECR repository URLs."
  value       = { for name, repository in aws_ecr_repository.identity : name => repository.repository_url }
}

output "github_deployment_role_arn" {
  description = "Non-secret short-lived Identity service GitHub deployment role ARN."
  value       = aws_iam_role.github_identity_deployer.arn
}

output "document_names" {
  description = "Non-secret fixed Identity SSM document names."
  value       = { for operation, document in aws_ssm_document.identity : operation => document.name }
}
