variable "budget_name" {
  description = "Domain-neutral monthly budget name."
  type        = string

  validation {
    condition     = length(trimspace(var.budget_name)) > 0
    error_message = "budget_name must not be empty."
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
}

variable "critical_usd" {
  description = "Actual and forecast critical threshold in USD."
  type        = number
}

variable "hard_usd" {
  description = "Monthly budget limit and hard-review threshold in USD."
  type        = number
}
