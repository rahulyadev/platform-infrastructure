locals {
  resource_server_identifier     = "identity-service://api"
  profile_read_scope_identifier  = "${local.resource_server_identifier}/profile.read"
  profile_write_scope_identifier = "${local.resource_server_identifier}/profile.write"
}

resource "aws_cognito_user_pool" "this" {
  name                = "${var.name_prefix}-identity-users"
  user_pool_tier      = "ESSENTIALS"
  deletion_protection = "ACTIVE"
  mfa_configuration   = "OFF"

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 16
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 1
  }

  schema {
    attribute_data_type      = "String"
    developer_only_attribute = false
    mutable                  = true
    name                     = "email"
    required                 = true

    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  username_configuration {
    case_sensitive = true
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

resource "aws_cognito_resource_server" "identity_api" {
  identifier = local.resource_server_identifier
  name       = "Identity service API"

  scope {
    scope_name        = "profile.read"
    scope_description = "Read the authenticated user's identity profile"
  }

  scope {
    scope_name        = "profile.write"
    scope_description = "Create or update the authenticated user's identity profile"
  }

  user_pool_id = aws_cognito_user_pool.this.id
}
