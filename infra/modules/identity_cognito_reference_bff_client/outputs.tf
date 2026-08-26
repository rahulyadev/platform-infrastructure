output "client_id" {
  description = "Reference BFF Cognito app-client ID."
  value       = aws_cognito_user_pool_client.reference_bff.id
}

output "callback_urls" {
  description = "Exact callback URLs derived from the validated application origins."
  value       = local.callback_urls
}

output "logout_urls" {
  description = "Exact logout URLs derived from the validated application origins."
  value       = local.logout_urls
}

output "client_secret" {
  description = "Reference BFF app-client secret for later secret-custody wiring only."
  value       = aws_cognito_user_pool_client.reference_bff.client_secret
  sensitive   = true
}
