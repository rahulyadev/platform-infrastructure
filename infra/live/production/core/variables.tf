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
  description = "Deployment environment used in names and tags."
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
  description = "Expected twelve-digit AWS account ID; supplied at runtime."
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

variable "availability_zone" {
  description = "Availability Zone for the single public subnet."
  type        = string
  default     = "ap-south-1a"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone must be a valid AWS Availability Zone name."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the custom VPC."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "public_subnet_cidr" {
  description = "IPv4 CIDR for the public subnet."
  type        = string
  default     = "10.42.10.0/24"

  validation {
    condition     = can(cidrnetmask(var.public_subnet_cidr))
    error_message = "public_subnet_cidr must be a valid IPv4 CIDR."
  }
}

variable "instance_type" {
  description = "ARM64-compatible EC2 instance type."
  type        = string
  default     = "t4g.small"

  validation {
    condition     = can(regex("^[a-z0-9]+[a-z0-9.]*$", var.instance_type))
    error_message = "instance_type must be a valid EC2 instance type name."
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
  description = "Optional permissions boundary for the EC2 instance role."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.permissions_boundary_arn == null || can(regex("^arn:[^:]+:iam::[0-9]{12}:policy/.+$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be null or an IAM policy ARN."
  }
}

variable "enable_identity_cognito_core" {
  description = "Create the Cognito User Pool and Identity API resource server."
  type        = bool
  default     = false
}
