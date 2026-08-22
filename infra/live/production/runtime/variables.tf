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
