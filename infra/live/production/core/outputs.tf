output "domains" {
  description = "Configured non-sensitive platform domain map."
  value       = local.domains
}

output "artifact_bucket_name" {
  description = "Private artifact bucket name."
  value       = module.artifact_bucket.bucket_name
}

output "artifact_bucket_arn" {
  description = "Private artifact bucket ARN."
  value       = module.artifact_bucket.bucket_arn
}

output "backup_bucket_name" {
  description = "Private backup bucket name."
  value       = module.backup_bucket.bucket_name
}

output "backup_bucket_arn" {
  description = "Private backup bucket ARN."
  value       = module.backup_bucket.bucket_arn
}

output "vpc_id" {
  description = "Custom VPC ID."
  value       = module.network.vpc_id
}

output "public_subnet_id" {
  description = "Public subnet ID."
  value       = module.network.public_subnet_id
}

output "edge_security_group_id" {
  description = "Edge security group ID."
  value       = module.network.edge_security_group_id
}

output "route_table_id" {
  description = "Public route table ID."
  value       = module.network.route_table_id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID."
  value       = module.network.internet_gateway_id
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = module.host.instance_id
}

output "instance_arn" {
  description = "EC2 instance ARN."
  value       = module.host.instance_arn
}

output "elastic_ip" {
  description = "Elastic IP assigned to the host."
  value       = module.host.elastic_ip
}

output "instance_role_arn" {
  description = "EC2 instance role ARN."
  value       = module.host.instance_role_arn
}

output "instance_profile_name" {
  description = "EC2 instance profile name."
  value       = module.host.instance_profile_name
}

output "root_volume_id" {
  description = "Encrypted gp3 root volume ID."
  value       = module.host.root_volume_id
}

output "identity_cognito_user_pool_id" {
  description = "Cognito User Pool ID when the disabled-by-default Identity core is enabled."
  value       = var.enable_identity_cognito_core ? module.identity_cognito_core[0].user_pool_id : null
}

output "identity_cognito_user_pool_arn" {
  description = "Cognito User Pool ARN when the disabled-by-default Identity core is enabled."
  value       = var.enable_identity_cognito_core ? module.identity_cognito_core[0].user_pool_arn : null
}

output "identity_cognito_user_pool_endpoint" {
  description = "Regional Cognito endpoint when the disabled-by-default Identity core is enabled."
  value       = var.enable_identity_cognito_core ? module.identity_cognito_core[0].user_pool_endpoint : null
}

output "identity_cognito_resource_server_identifier" {
  description = "Exact Identity API OAuth resource identifier when the Cognito core is enabled."
  value       = var.enable_identity_cognito_core ? module.identity_cognito_core[0].resource_server_identifier : null
}

output "identity_cognito_profile_read_scope_identifier" {
  description = "Exact profile-read scope when the Cognito core is enabled."
  value       = var.enable_identity_cognito_core ? module.identity_cognito_core[0].profile_read_scope_identifier : null
}

output "identity_cognito_profile_write_scope_identifier" {
  description = "Exact profile-write scope when the Cognito core is enabled."
  value       = var.enable_identity_cognito_core ? module.identity_cognito_core[0].profile_write_scope_identifier : null
}

output "identity_reference_bff_client_id" {
  description = "Reference BFF Cognito app-client ID when its disabled-by-default gate is enabled."
  value       = var.enable_identity_reference_bff_client ? module.identity_cognito_reference_bff_client[0].client_id : null
}

output "identity_reference_bff_callback_urls" {
  description = "Validated reference-BFF callback URLs when its disabled-by-default gate is enabled."
  value       = var.enable_identity_reference_bff_client ? module.identity_cognito_reference_bff_client[0].callback_urls : null
}

output "identity_reference_bff_logout_urls" {
  description = "Validated reference-BFF logout URLs when its disabled-by-default gate is enabled."
  value       = var.enable_identity_reference_bff_client ? module.identity_cognito_reference_bff_client[0].logout_urls : null
}
