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
  description = "Tag value for the state bootstrap environment."
  type        = string
  default     = "bootstrap-state"
}

variable "aws_region" {
  description = "AWS region in which the state bucket will be created."
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

variable "state_suffix" {
  description = "Domain-neutral suffix for the remote state bucket."
  type        = string
  default     = "state"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.state_suffix))
    error_message = "state_suffix must contain lowercase letters, numbers, and hyphens."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days to retain noncurrent state object versions."
  type        = number
  default     = 365
}
