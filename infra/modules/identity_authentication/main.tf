resource "aws_acm_certificate" "auth" {
  provider = aws.us_east_1
  count    = var.enable_certificate_request ? 1 : 0

  domain_name       = var.auth_domain
  validation_method = "DNS"

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate_validation" "auth" {
  provider = aws.us_east_1
  count    = var.enable_certificate_validation ? 1 : 0

  certificate_arn         = one(aws_acm_certificate.auth[*].arn)
  validation_record_fqdns = var.certificate_validation_record_fqdns
}

data "aws_secretsmanager_secret_version" "google" {
  count = var.enable_google_federation ? 1 : 0

  secret_id     = var.google_credentials_secret_arn
  version_stage = "AWSCURRENT"
}

locals {
  google_credentials = var.enable_google_federation ? jsondecode(one(data.aws_secretsmanager_secret_version.google[*].secret_string)) : {}
  issuer             = var.user_pool_id == null ? null : format("https://cognito-idp.%s.amazonaws.com/%s", var.aws_region, var.user_pool_id)
}

resource "aws_cognito_identity_provider" "google" {
  count = var.enable_google_federation ? 1 : 0

  user_pool_id    = var.user_pool_id
  provider_name   = "Google"
  provider_type   = "Google"
  idp_identifiers = []

  provider_details = {
    authorize_scopes = "openid email"
    client_id        = try(local.google_credentials.client_id, null)
    client_secret    = try(local.google_credentials.client_secret, null)
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    username       = "sub"
  }

  lifecycle {
    prevent_destroy = true

    ignore_changes = [
      provider_details["attributes_url"],
      provider_details["attributes_url_add_attributes"],
      provider_details["authorize_url"],
      provider_details["oidc_issuer"],
      provider_details["token_request_method"],
      provider_details["token_url"],
    ]

    precondition {
      condition = (
        try(length(local.google_credentials.client_id), 0) > 0 &&
        try(length(local.google_credentials.client_secret), 0) > 0
      )
      error_message = "Google federation requires nonempty client_id and client_secret fields in the referenced secret version."
    }
  }
}

resource "aws_cognito_user_pool_domain" "auth" {
  count = var.enable_user_pool_domain ? 1 : 0

  domain          = var.auth_domain
  user_pool_id    = var.user_pool_id
  certificate_arn = one(aws_acm_certificate_validation.auth[*].certificate_arn)

  depends_on = [aws_cognito_identity_provider.google]

  lifecycle {
    prevent_destroy = true
  }
}
