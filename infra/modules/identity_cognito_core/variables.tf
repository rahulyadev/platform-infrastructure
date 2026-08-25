variable "name_prefix" {
  description = "Domain-neutral prefix for the Cognito user pool name."
  type        = string

  validation {
    condition = (
      length(var.name_prefix) <= 96 &&
      can(regex("^[a-z0-9][a-z0-9-]*$", var.name_prefix))
    )
    error_message = "name_prefix must be at most 96 lowercase alphanumeric or hyphen characters."
  }
}

variable "tags" {
  description = "Canonical tags applied to resources that support tagging."
  type        = map(string)
  default     = {}
}
