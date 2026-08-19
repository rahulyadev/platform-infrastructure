variable "bucket_name" {
  description = "Globally unique, domain-neutral S3 bucket name."
  type        = string

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63 && can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid lowercase S3 bucket name between 3 and 63 characters."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days to retain noncurrent object versions."
  type        = number
  default     = 365

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "tags" {
  description = "Additional domain-neutral resource tags."
  type        = map(string)
  default     = {}
}
