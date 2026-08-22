variable "name_prefix" {
  description = "Domain-neutral prefix for runtime monitoring resources."
  type        = string
}

variable "aws_region" {
  description = "Region containing the monitored instance."
  type        = string
}

variable "instance_id" {
  description = "Exact production EC2 instance ID."
  type        = string

  validation {
    condition     = can(regex("^i-[0-9a-f]+$", var.instance_id))
    error_message = "instance_id must be an EC2 instance identifier."
  }
}

variable "instance_role_name" {
  description = "Existing production instance role that receives telemetry permissions."
  type        = string
}

variable "alert_email_addresses" {
  description = "Validated email endpoints for alarm notifications."
  type        = set(string)
}

variable "log_retention_days" {
  description = "Retention in days for the four exact runtime log groups."
  type = object({
    nginx_access = number
    nginx_error  = number
    deployment   = number
    system       = number
  })
}

variable "metric_namespace" {
  description = "CloudWatch Agent custom metric namespace."
  type        = string
}

variable "cloudwatch_agent_config" {
  description = "Non-secret rendered CloudWatch Agent configuration."
  type        = string
}

variable "cloudwatch_agent_version" {
  description = "Exact SSM Distributor version of AmazonCloudWatchAgent."
  type        = string
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
  default     = {}
}
