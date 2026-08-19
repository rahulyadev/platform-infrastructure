output "bucket_name" {
  description = "Planned remote state bucket name."
  value       = module.state_bucket.bucket_name
}

output "bucket_arn" {
  description = "Planned remote state bucket ARN."
  value       = module.state_bucket.bucket_arn
}

output "region" {
  description = "Remote state bucket region."
  value       = var.aws_region
}

output "suggested_bootstrap_state_key" {
  description = "Suggested key when this bootstrap state is migrated to S3."
  value       = "bootstrap/state/tofu.tfstate"
}

output "suggested_production_core_state_key" {
  description = "Required production core backend key."
  value       = "production/core/tofu.tfstate"
}
