variable "name_prefix" {
  description = "Domain-neutral prefix for deployment resources."
  type        = string
}

variable "aws_region" {
  description = "Region containing the production instance and artifact bucket."
  type        = string
}

variable "expected_account_id" {
  description = "Expected AWS account ID used only to scope role permissions."
  type        = string
}

variable "instance_id" {
  description = "Exact production EC2 instance ID."
  type        = string
}

variable "instance_arn" {
  description = "Exact production EC2 instance ARN."
  type        = string
}

variable "artifact_bucket_name" {
  description = "Private artifact bucket name."
  type        = string
}

variable "artifact_bucket_arn" {
  description = "Private artifact bucket ARN."
  type        = string
}

variable "github_owner" {
  description = "GitHub repository owner name."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable GitHub owner database ID."
  type        = number
}

variable "github_repository_id" {
  description = "Immutable GitHub repository database ID."
  type        = number
}

variable "github_environment" {
  description = "Protected GitHub deployment environment."
  type        = string
}

variable "configure_runtime_script" {
  description = "Fully rendered fixed runtime-configuration script."
  type        = string
}

variable "deploy_portfolio_script" {
  description = "Fixed immutable portfolio deployment script."
  type        = string
}

variable "rollback_portfolio_script" {
  description = "Fixed immutable portfolio rollback script."
  type        = string
}

variable "enable_tls_script" {
  description = "Fully rendered fixed TLS-enablement script."
  type        = string
}

variable "base_domain" {
  description = "Configured portfolio apex domain."
  type        = string
}

variable "expected_elastic_ip" {
  description = "Stable public IPv4 address required by the TLS document."
  type        = string
}

variable "tags" {
  description = "Tags applied to supported resources."
  type        = map(string)
  default     = {}
}
