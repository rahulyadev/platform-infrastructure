variable "project_name" {
  description = "Domain-neutral project identifier used in names and tags."
  type        = string
  default     = "platform-infrastructure"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.project_name))
    error_message = "project_name must contain lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment used in names and tags."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.environment))
    error_message = "environment must contain lowercase letters, numbers, and hyphens."
  }
}

variable "aws_region" {
  description = "AWS application region."
  type        = string
  default     = "ap-south-1"
}

variable "expected_account_id" {
  description = "Expected twelve-digit AWS account ID; supplied at runtime."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must contain exactly twelve digits."
  }
}

variable "base_domain" {
  description = "DNS base domain without scheme, path, wildcard, or trailing dot."
  type        = string

  validation {
    condition = (
      length(var.base_domain) <= 253 &&
      var.base_domain == lower(var.base_domain) &&
      !strcontains(var.base_domain, "://") &&
      !strcontains(var.base_domain, "/") &&
      !strcontains(var.base_domain, "*") &&
      !endswith(var.base_domain, ".") &&
      can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.base_domain))
    )
    error_message = "base_domain must be a lowercase DNS name without scheme, path, wildcard, or trailing dot."
  }
}

variable "availability_zone" {
  description = "Availability Zone for the single public subnet."
  type        = string
  default     = "ap-south-1a"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone must be a valid AWS Availability Zone name."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the custom VPC."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "public_subnet_cidr" {
  description = "IPv4 CIDR for the public subnet."
  type        = string
  default     = "10.42.10.0/24"

  validation {
    condition     = can(cidrnetmask(var.public_subnet_cidr))
    error_message = "public_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "instance_type" {
  description = "ARM64-compatible EC2 instance type."
  type        = string
  default     = "t4g.medium"

  validation {
    condition     = can(regex("^[a-z0-9]+[a-z0-9.]*$", var.instance_type))
    error_message = "instance_type must be a valid EC2 instance type name."
  }
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root volume size in GiB."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size_gib >= 8
    error_message = "root_volume_size_gib must be at least 8 GiB."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the EC2 instance role."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.permissions_boundary_arn == null || can(regex("^arn:[^:]+:iam::[0-9]{12}:policy/.+$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be null or an IAM policy ARN."
  }
}

variable "enable_identity_cognito_core" {
  description = "Create the Cognito User Pool and Identity API resource server."
  type        = bool
  default     = false
}

variable "enable_identity_reference_bff_client" {
  description = "Create the confidential Cognito app client for the production reference BFF."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_identity_reference_bff_client || (
      var.enable_identity_cognito_core &&
      var.enable_identity_google_federation &&
      var.enable_identity_auth_domain &&
      var.identity_reference_bff_application_origins == [format("https://%s", var.base_domain)]
    )
    error_message = "enable_identity_reference_bff_client requires the Cognito core, Google federation, and user-pool domain gates plus the exact portfolio origin."
  }
}

variable "enable_identity_auth_certificate" {
  description = "Request the auth-domain ACM certificate in us-east-1 after the external DNS owner is ready."
  type        = bool
  default     = false
}

variable "enable_identity_auth_certificate_validation" {
  description = "Complete auth-domain certificate validation after the external DNS records are verified."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_identity_auth_certificate_validation || (
      var.enable_identity_auth_certificate &&
      length(var.identity_auth_certificate_validation_record_fqdns) > 0
    )
    error_message = "enable_identity_auth_certificate_validation requires the certificate gate and verified external DNS validation records."
  }
}

variable "identity_auth_certificate_validation_record_fqdns" {
  description = "Externally managed ACM validation record FQDNs; empty until the validation checkpoint."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = length(distinct(var.identity_auth_certificate_validation_record_fqdns)) == length(var.identity_auth_certificate_validation_record_fqdns) && alltrue([
      for record in var.identity_auth_certificate_validation_record_fqdns :
      record == lower(record) &&
      !strcontains(record, "*") &&
      can(regex("^([a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?[.]){2,}[a-z0-9-]{2,63}[.]?$", record))
    ])
    error_message = "identity_auth_certificate_validation_record_fqdns must contain unique lowercase DNS validation record names without wildcards."
  }
}

variable "enable_identity_google_federation" {
  description = "Create the Google Cognito identity provider after the credentials secret reference is provisioned."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_identity_google_federation || (
      var.enable_identity_cognito_core &&
      var.identity_google_credentials_secret_arn != null
    )
    error_message = "enable_identity_google_federation requires the Cognito core gate and a Google credentials secret reference."
  }
}

variable "identity_google_credentials_secret_arn" {
  description = "Secrets Manager ARN containing client_id and client_secret for the future Google federation checkpoint."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_google_credentials_secret_arn == null || can(regex("^arn:aws:secretsmanager:ap-south-1:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", var.identity_google_credentials_secret_arn))
    error_message = "identity_google_credentials_secret_arn must be null or an ap-south-1 Secrets Manager secret ARN."
  }
}

variable "enable_identity_auth_domain" {
  description = "Attach the auth-domain custom Cognito endpoint after ACM validation and Google federation."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_identity_auth_domain || (
      var.enable_identity_cognito_core &&
      var.enable_identity_auth_certificate_validation &&
      var.enable_identity_google_federation
    )
    error_message = "enable_identity_auth_domain requires Cognito core, validated certificate, and Google federation gates."
  }
}

variable "enable_identity_client_secret_custody" {
  description = "Store the generated reference-BFF client secret only after the confidential client is enabled."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_identity_client_secret_custody || var.enable_identity_reference_bff_client
    error_message = "enable_identity_client_secret_custody requires the reference-BFF client gate."
  }
}

variable "identity_reference_bff_application_origins" {
  description = "Validated production reference-BFF origins; empty while the client gate is disabled."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = (
      length(var.identity_reference_bff_application_origins) <= 4 &&
      length(distinct(var.identity_reference_bff_application_origins)) == length(var.identity_reference_bff_application_origins) &&
      alltrue([
        for origin in var.identity_reference_bff_application_origins :
        length(origin) <= 261 &&
        origin == lower(origin) &&
        can(regex("^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", origin))
      ])
    )
    error_message = "identity_reference_bff_application_origins must be empty or contain up to four unique exact lowercase HTTPS DNS origins without userinfo, wildcard, IP literal, port, path, query, fragment, percent encoding, trailing slash, whitespace, control, or non-ASCII characters."
  }
}
