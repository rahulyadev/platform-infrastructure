variable "name_prefix" {
  description = "Domain-neutral prefix for snapshot resources."
  type        = string
}

variable "target_instance_tags" {
  description = "Exact production instance tags selected by DLM."
  type        = map(string)

  validation {
    condition     = length(var.target_instance_tags) >= 3
    error_message = "target_instance_tags must uniquely identify the production instance."
  }
}

variable "daily_snapshot_retention_count" {
  description = "Daily snapshots retained by DLM."
  type        = number
}

variable "monthly_snapshot_retention_count" {
  description = "Monthly snapshots retained by DLM."
  type        = number
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
  default     = {}
}
