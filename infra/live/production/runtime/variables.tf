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
  description = "Deployment environment used in names, tags, and monitoring dimensions."
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
  description = "Expected twelve-digit AWS account ID; supplied only in the ignored local variable file."
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

variable "alert_email_addresses" {
  description = "Email endpoints that must confirm SNS subscriptions after apply."
  type        = set(string)

  validation {
    condition = (
      length(var.alert_email_addresses) > 0 &&
      alltrue([
        for address in var.alert_email_addresses :
        can(regex("^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$", address))
      ])
    )
    error_message = "alert_email_addresses must contain at least one syntactically valid email address."
  }
}

variable "github_owner" {
  description = "GitHub repository owner name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_owner))
    error_message = "github_owner must be a valid GitHub owner name."
  }
}

variable "github_repository" {
  description = "GitHub repository name trusted for deployment."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be a valid GitHub repository name."
  }
}

variable "github_owner_id" {
  description = "Immutable positive GitHub owner database ID."
  type        = number

  validation {
    condition     = var.github_owner_id > 0 && floor(var.github_owner_id) == var.github_owner_id
    error_message = "github_owner_id must be a positive integer."
  }
}

variable "github_repository_id" {
  description = "Immutable positive GitHub repository database ID."
  type        = number

  validation {
    condition     = var.github_repository_id > 0 && floor(var.github_repository_id) == var.github_repository_id
    error_message = "github_repository_id must be a positive integer."
  }
}

variable "github_environment" {
  description = "Protected GitHub environment permitted to deploy."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.github_environment))
    error_message = "github_environment must be a valid GitHub environment name."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for each runtime log category."
  type = object({
    nginx_access = number
    nginx_error  = number
    deployment   = number
    system       = number
  })

  validation {
    condition = alltrue([
      for days in values(var.log_retention_days) : days > 0 && floor(days) == days
    ])
    error_message = "Every log retention value must be a positive integer."
  }
}

variable "runtime_package_versions" {
  description = "Exact discovered package identities for the Amazon Linux 2023 ARM64 host."
  type = object({
    nginx                   = string
    aws_cli                 = string
    python                  = string
    python_libraries        = string
    python_pip              = string
    python_pip_wheel        = string
    python_setuptools       = string
    python_setuptools_wheel = string
    python_wheel            = string
    amazon_cloudwatch_agent = string
  })

  validation {
    condition = alltrue([
      for package in values(var.runtime_package_versions) :
      length(package) > 0 && !strcontains(package, " ")
    ])
    error_message = "Runtime package identities must be non-empty and contain no spaces."
  }
}

variable "certbot_version" {
  description = "Exact Certbot Python package version installed in the isolated virtual environment."
  type        = string
  default     = "5.7.0"

  validation {
    condition     = var.certbot_version == "5.7.0"
    error_message = "This release requires certbot_version 5.7.0."
  }
}

variable "daily_snapshot_retention_count" {
  description = "Number of daily DLM snapshots to retain."
  type        = number
  default     = 7

  validation {
    condition     = var.daily_snapshot_retention_count == 7
    error_message = "The reviewed daily snapshot retention is seven."
  }
}

variable "monthly_snapshot_retention_count" {
  description = "Number of monthly DLM snapshots to retain."
  type        = number
  default     = 3

  validation {
    condition     = var.monthly_snapshot_retention_count == 3
    error_message = "The reviewed monthly snapshot retention is three."
  }
}

variable "enable_identity_delivery_foundation" {
  description = "Create the default-disabled Identity image, OIDC, host-permission, SSM, and monitoring foundation."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_identity_delivery_foundation || (
      var.identity_github_owner == "rahulyadev" &&
      var.identity_github_repository == "identity-service" &&
      var.identity_github_owner_id != null &&
      var.identity_github_repository_id != null &&
      var.identity_bff_client_secret_arn != null &&
      var.identity_database_secret_arn != null &&
      var.identity_redis_secret_arn != null &&
      var.identity_backup_secret_arn != null
    )
    error_message = "enable_identity_delivery_foundation requires the exact Identity service repository, immutable GitHub IDs, and all non-Google runtime secret references."
  }
}

variable "enable_identity_production_runtime" {
  description = "Configure the production Identity runtime only after delivery foundations and immutable ARM64 images are supplied."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_identity_production_runtime || (
      var.enable_identity_delivery_foundation &&
      var.identity_api_image != null &&
      var.identity_bff_image != null &&
      startswith(var.identity_api_image, format("%s.dkr.ecr.%s.amazonaws.com/%s-%s-identity-api@sha256:", var.expected_account_id, var.aws_region, var.project_name, var.environment)) &&
      startswith(var.identity_bff_image, format("%s.dkr.ecr.%s.amazonaws.com/%s-%s-identity-bff@sha256:", var.expected_account_id, var.aws_region, var.project_name, var.environment)) &&
      var.identity_api_image_platform == "linux/arm64" &&
      var.identity_bff_image_platform == "linux/arm64" &&
      var.identity_auth_certificate_arn != null &&
      var.identity_cognito_issuer != null &&
      var.identity_cognito_jwks_uri == format("%s/.well-known/jwks.json", var.identity_cognito_issuer) &&
      var.identity_cognito_audience == "identity-service://api" &&
      var.identity_cognito_client_id != null &&
      var.identity_bff_origin == "https://rahuly.in" &&
      var.identity_redis_namespace == "reference-bff:production:portfolio:identity"
    )
    error_message = "enable_identity_production_runtime requires delivery, ARM64 image proofs, every reviewed authentication reference, the exact portfolio origin, and the exact Redis namespace."
  }
}

variable "identity_api_image_platform" {
  description = "Externally verified API manifest platform; null until digest proof."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_bff_image_platform" {
  description = "Externally verified BFF manifest platform; null until digest proof."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_auth_certificate_arn" {
  description = "Validated auth-domain ACM certificate ARN; null until the authentication checkpoint."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_cognito_issuer" {
  description = "Regional Cognito issuer; null until the authentication checkpoint."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_cognito_issuer == null || can(regex("^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+$", var.identity_cognito_issuer))
    error_message = "identity_cognito_issuer must be null or the exact ap-south-1 regional issuer."
  }
}

variable "identity_cognito_jwks_uri" {
  description = "Exact Cognito JWKS URI; null until the authentication checkpoint."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_cognito_audience" {
  description = "Exact Identity API resource audience; null until the authentication checkpoint."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_cognito_audience == null || var.identity_cognito_audience == "identity-service://api"
    error_message = "identity_cognito_audience must be null or the exact Identity resource identifier."
  }
}

variable "identity_cognito_client_id" {
  description = "Non-secret reference-BFF Cognito app-client identifier; null until provisioned."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_cognito_client_id == null || can(regex("^[a-z0-9]{26}$", var.identity_cognito_client_id))
    error_message = "identity_cognito_client_id must be null or an exact Cognito client identifier."
  }
}

variable "identity_bff_origin" {
  description = "Exact production same-origin BFF origin; null until activation."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_bff_origin == null || var.identity_bff_origin == "https://rahuly.in"
    error_message = "identity_bff_origin must be null or the exact production apex origin."
  }
}

variable "identity_redis_namespace" {
  description = "Exact BFF-only disposable Redis namespace."
  type        = string
  default     = "reference-bff:production:portfolio:identity"

  validation {
    condition     = var.identity_redis_namespace == "reference-bff:production:portfolio:identity"
    error_message = "identity_redis_namespace must remain the exact published BFF namespace."
  }
}

variable "identity_api_image" {
  description = "Immutable ARM64 Identity API image reference; null while runtime is disabled."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_api_image == null || can(regex("^[a-z0-9.-]+(?:[:][0-9]+)?/[a-z0-9/_-]+@sha256:[0-9a-f]{64}$", var.identity_api_image))
    error_message = "identity_api_image must be null or an immutable repository@sha256 reference."
  }
}

variable "identity_bff_image" {
  description = "Immutable ARM64 reference-BFF image reference; null while runtime is disabled."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.identity_bff_image == null || can(regex("^[a-z0-9.-]+(?:[:][0-9]+)?/[a-z0-9/_-]+@sha256:[0-9a-f]{64}$", var.identity_bff_image))
    error_message = "identity_bff_image must be null or an immutable repository@sha256 reference."
  }
}

variable "identity_github_owner" {
  description = "Exact Identity service GitHub owner."
  type        = string
  default     = "rahulyadev"
}

variable "identity_github_repository" {
  description = "Exact Identity service GitHub repository."
  type        = string
  default     = "identity-service"
}

variable "identity_github_owner_id" {
  description = "Immutable Identity service GitHub owner database ID; null until activation proof."
  type        = number
  default     = null
  nullable    = true
}

variable "identity_github_repository_id" {
  description = "Immutable Identity service GitHub repository database ID; null until activation proof."
  type        = number
  default     = null
  nullable    = true
}

variable "identity_github_environment" {
  description = "Exact protected Identity service GitHub deployment environment."
  type        = string
  default     = "production"
}

variable "identity_bff_client_secret_arn" {
  description = "Reference-BFF Cognito client secret ARN; null until secret custody is provisioned."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_database_secret_arn" {
  description = "Identity database credential secret ARN; null until separately provisioned."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_redis_secret_arn" {
  description = "Identity Redis ACL credential secret ARN; null until separately provisioned."
  type        = string
  default     = null
  nullable    = true
}

variable "identity_backup_secret_arn" {
  description = "Identity pgBackRest repository-encryption secret ARN; null until separately provisioned."
  type        = string
  default     = null
  nullable    = true
}
