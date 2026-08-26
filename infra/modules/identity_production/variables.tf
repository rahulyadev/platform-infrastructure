variable "name_prefix" {
  description = "Canonical platform production name prefix."
  type        = string
}

variable "aws_region" {
  description = "Identity production AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "expected_account_id" {
  description = "Expected AWS account ID."
  type        = string
}

variable "instance_id" {
  description = "Existing production host instance ID."
  type        = string
}

variable "instance_role_name" {
  description = "Existing production host IAM role name."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub Actions OIDC provider ARN."
  type        = string
}

variable "github_owner" {
  description = "Exact Identity service GitHub owner."
  type        = string
}

variable "github_repository" {
  description = "Exact Identity service GitHub repository."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable Identity service GitHub owner database ID."
  type        = number
}

variable "github_repository_id" {
  description = "Immutable Identity service GitHub repository database ID."
  type        = number
}

variable "github_environment" {
  description = "Exact protected GitHub deployment environment."
  type        = string
  default     = "production"
}

variable "backup_bucket_arn" {
  description = "Existing versioned backup bucket ARN."
  type        = string
}

variable "runtime_secret_arns" {
  description = "Exact host-readable Identity runtime secret ARNs; Google federation credentials are forbidden."
  type        = set(string)

  validation {
    condition = length(var.runtime_secret_arns) >= 5 && alltrue([
      for arn in var.runtime_secret_arns :
      can(regex("^arn:aws:secretsmanager:ap-south-1:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", arn)) &&
      !strcontains(lower(arn), "google")
    ])
    error_message = "runtime_secret_arns must contain exact ap-south-1 non-Google runtime secret ARNs."
  }
}

variable "enable_runtime" {
  description = "Associate the fixed runtime configuration document with the host."
  type        = bool
  default     = false
}

variable "document_scripts" {
  description = "Reviewed fixed SSM document scripts."
  type = object({
    configure = string
    deploy    = string
    tls       = string
    verify    = string
    rollback  = string
    backup    = string
    restore   = string
  })
}

variable "log_retention_days" {
  description = "Identity log retention in days."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}
