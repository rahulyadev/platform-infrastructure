variable "name_prefix" {
  description = "Domain-neutral resource name prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.name_prefix))
    error_message = "name_prefix must contain lowercase letters, numbers, and hyphens."
  }
}

variable "ami_id" {
  description = "ARM64 Amazon Linux 2023 AMI ID supplied by the root."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must be an EC2 AMI identifier."
  }
}

variable "instance_type" {
  description = "ARM64-compatible EC2 instance type."
  type        = string
  default     = "t4g.small"
}

variable "subnet_id" {
  description = "Subnet in which to launch the host."
  type        = string
}

variable "security_group_id" {
  description = "Security group assigned to the host."
  type        = string
}

variable "artifact_bucket_arn" {
  description = "ARN of the private artifact bucket readable by the host."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:s3:::[a-z0-9][a-z0-9.-]*$", var.artifact_bucket_arn))
    error_message = "artifact_bucket_arn must be an S3 bucket ARN."
  }
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root volume size in GiB."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size_gib >= 8
    error_message = "root_volume_size_gib must be at least 8 GiB."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the EC2 role."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.permissions_boundary_arn == null || can(regex("^arn:[^:]+:iam::[0-9]{12}:policy/.+$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be null or an IAM policy ARN."
  }
}

variable "tags" {
  description = "Additional domain-neutral resource tags."
  type        = map(string)
  default     = {}
}
