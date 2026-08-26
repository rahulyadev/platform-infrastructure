locals {
  callback_urls = sort([
    for origin in var.application_origins : "${origin}/auth/callback"
  ])
  logout_urls = sort([
    for origin in var.application_origins : "${origin}/auth/signed-out"
  ])
}

resource "aws_cognito_user_pool_client" "reference_bff" {
  name         = "${var.name_prefix}-reference-bff"
  user_pool_id = var.user_pool_id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes = [
    "openid",
    var.profile_read_scope_identifier,
    var.profile_write_scope_identifier,
  ]
  supported_identity_providers = ["Google"]
  explicit_auth_flows          = []

  callback_urls = local.callback_urls
  logout_urls   = local.logout_urls

  access_token_validity  = 15
  id_token_validity      = 15
  refresh_token_validity = 14

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  refresh_token_rotation {
    feature                    = "ENABLED"
    retry_grace_period_seconds = 10
  }

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"
  auth_session_validity         = 3

  read_attributes  = ["email", "email_verified"]
  write_attributes = ["email"]

  lifecycle {
    prevent_destroy = true
  }
}
