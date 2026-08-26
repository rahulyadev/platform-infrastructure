variable "user_pool_id" {
  description = "Existing Cognito User Pool ID for the reference BFF app client."
  type        = string
  nullable    = false

  validation {
    condition = (
      length(var.user_pool_id) <= 55 &&
      can(regex("^[a-z]{2}(-[a-z0-9]+)*-[0-9]+_[A-Za-z0-9]+$", var.user_pool_id))
    )
    error_message = "user_pool_id must be a valid existing Cognito User Pool ID."
  }
}

variable "profile_read_scope_identifier" {
  description = "Exact fully qualified Identity API profile-read scope."
  type        = string
  nullable    = false

  validation {
    condition     = var.profile_read_scope_identifier == "identity-service://api/profile.read"
    error_message = "profile_read_scope_identifier must be the exact reviewed Identity API profile-read scope."
  }
}

variable "profile_write_scope_identifier" {
  description = "Exact fully qualified Identity API profile-write scope."
  type        = string
  nullable    = false

  validation {
    condition     = var.profile_write_scope_identifier == "identity-service://api/profile.write"
    error_message = "profile_write_scope_identifier must be the exact reviewed Identity API profile-write scope."
  }
}

variable "name_prefix" {
  description = "Canonical domain-neutral prefix for the reference BFF app-client name."
  type        = string
  nullable    = false

  validation {
    condition = (
      length(var.name_prefix) <= 96 &&
      can(regex("^[a-z0-9][a-z0-9-]*$", var.name_prefix))
    )
    error_message = "name_prefix must be at most 96 lowercase alphanumeric or hyphen characters."
  }
}

variable "application_origins" {
  description = "One to four unique lowercase HTTPS DNS origins for the production reference BFF."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.application_origins) >= 1 &&
      length(var.application_origins) <= 4 &&
      length(distinct(var.application_origins)) == length(var.application_origins) &&
      alltrue([
        for origin in var.application_origins :
        length(origin) <= 261 &&
        origin == lower(origin) &&
        can(regex("^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", origin))
      ])
    )
    error_message = "application_origins must contain one to four unique exact lowercase HTTPS DNS origins without userinfo, wildcard, IP literal, port, path, query, fragment, percent encoding, trailing slash, whitespace, control, or non-ASCII characters."
  }
}
