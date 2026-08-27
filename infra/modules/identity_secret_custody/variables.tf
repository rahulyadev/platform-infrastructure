variable "name_prefix" {
  description = "Canonical platform production name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.name_prefix))
    error_message = "name_prefix must be a canonical lowercase platform prefix."
  }
}

variable "client_secret" {
  description = "Generated confidential Cognito client secret; never exposed by a production-root output."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.client_secret) >= 32
    error_message = "client_secret must contain a generated confidential client value."
  }
}

variable "tags" {
  description = "Tags applied to the secret container."
  type        = map(string)
  default     = {}
}
