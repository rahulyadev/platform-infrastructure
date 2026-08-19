output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "instance_arn" {
  description = "EC2 instance ARN."
  value       = aws_instance.this.arn
}

output "elastic_ip" {
  description = "Elastic IP assigned to the host."
  value       = aws_eip.this.public_ip
}

output "instance_role_arn" {
  description = "EC2 instance role ARN."
  value       = aws_iam_role.this.arn
}

output "instance_profile_name" {
  description = "EC2 instance profile name."
  value       = aws_iam_instance_profile.this.name
}

output "root_volume_id" {
  description = "Encrypted gp3 root volume ID."
  value       = aws_instance.this.root_block_device[0].volume_id
}
