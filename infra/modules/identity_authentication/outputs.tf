output "certificate_arn" {
  description = "Non-secret ACM certificate ARN when requested."
  value       = var.enable_certificate_request ? aws_acm_certificate.auth[0].arn : null
}

output "certificate_dns_validation_records" {
  description = "Non-secret DNS records that the external DNS owner must create."
  value = var.enable_certificate_request ? [
    for option in aws_acm_certificate.auth[0].domain_validation_options : {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  ] : null
}

output "user_pool_domain" {
  description = "Non-secret custom Cognito domain when enabled."
  value       = var.enable_user_pool_domain ? aws_cognito_user_pool_domain.auth[0].domain : null
}

output "user_pool_domain_target" {
  description = "Non-secret Cognito-managed CloudFront target for the external DNS owner."
  value       = var.enable_user_pool_domain ? aws_cognito_user_pool_domain.auth[0].cloudfront_distribution : null
}

output "issuer" {
  description = "Non-secret Cognito issuer URL when the custom domain is enabled."
  value       = var.enable_user_pool_domain ? local.issuer : null
}

output "jwks_uri" {
  description = "Non-secret Cognito JWKS URI when the custom domain is enabled."
  value       = var.enable_user_pool_domain ? format("%s/.well-known/jwks.json", local.issuer) : null
}
