output "user_pool_id" {
  description = "Cognito User Pool ID."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN."
  value       = aws_cognito_user_pool.this.arn
}

output "user_pool_endpoint" {
  description = "Regional Cognito User Pool endpoint name."
  value       = aws_cognito_user_pool.this.endpoint
}

output "resource_server_identifier" {
  description = "Exact Identity API OAuth resource identifier."
  value       = aws_cognito_resource_server.identity_api.identifier
}

output "profile_read_scope_identifier" {
  description = "Exact fully qualified profile-read scope."
  value       = local.profile_read_scope_identifier
}

output "profile_write_scope_identifier" {
  description = "Exact fully qualified profile-write scope."
  value       = local.profile_write_scope_identifier
}
