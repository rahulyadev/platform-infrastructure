variable "name_prefix" {
  description = "Canonical platform production name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.name_prefix))
    error_message = "name_prefix must be a canonical lowercase platform prefix."
  }
}

variable "aws_region" {
  description = "Cognito application region used to derive the issuer and JWKS URI."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = var.aws_region == "ap-south-1"
    error_message = "aws_region must remain ap-south-1."
  }
}

variable "auth_domain" {
  description = "Exact custom authentication DNS name."
  type        = string

  validation {
    condition     = can(regex("^auth[.]([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?[.])+[a-z]{2,63}$", var.auth_domain))
    error_message = "auth_domain must be an exact lowercase auth DNS name."
  }
}

variable "user_pool_id" {
  description = "Existing Cognito User Pool ID when federation or the domain is enabled."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.user_pool_id == null || can(regex("^ap-south-1_[A-Za-z0-9]+$", var.user_pool_id))
    error_message = "user_pool_id must be null or an ap-south-1 Cognito User Pool ID."
  }
}

variable "enable_certificate_request" {
  description = "Request the us-east-1 ACM certificate."
  type        = bool
  default     = false
}

variable "enable_certificate_validation" {
  description = "Complete validation after external DNS records exist."
  type        = bool
  default     = false
}

variable "certificate_validation_record_fqdns" {
  description = "Externally managed ACM validation record FQDNs."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "enable_google_federation" {
  description = "Create the sole Google Cognito identity provider."
  type        = bool
  default     = false
}

variable "google_credentials_secret_arn" {
  description = "Secrets Manager ARN holding client_id and client_secret."
  type        = string
  default     = null
  nullable    = true
}

variable "enable_user_pool_domain" {
  description = "Create the direct custom Cognito domain."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to taggable resources."
  type        = map(string)
  default     = {}
}
