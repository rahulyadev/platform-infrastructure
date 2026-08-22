output "policy_id" {
  description = "Production DLM lifecycle policy ID."
  value       = aws_dlm_lifecycle_policy.production.id
}

output "execution_role_arn" {
  description = "DLM execution role ARN."
  value       = aws_iam_role.dlm.arn
}
