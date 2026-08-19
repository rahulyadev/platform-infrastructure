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
  description = "Tag value for the account bootstrap environment."
  type        = string
  default     = "bootstrap-account"
}

variable "aws_region" {
  description = "AWS region used for provider operations."
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

variable "notification_email_addresses" {
  description = "Non-empty set of budget notification recipients."
  type        = set(string)

  validation {
    condition = length(var.notification_email_addresses) > 0 && alltrue([
      for address in var.notification_email_addresses : can(regex("^[^@]+@[^@]+\\.[^@]+$", address))
    ])
    error_message = "Provide at least one syntactically valid notification email address."
  }
}

variable "warning_usd" {
  description = "Actual-spend warning threshold in USD."
  type        = number
  default     = 25
}

variable "critical_usd" {
  description = "Actual and forecast critical threshold in USD."
  type        = number
  default     = 35
}

variable "hard_usd" {
  description = "Monthly limit and hard-review threshold in USD."
  type        = number
  default     = 40
}
