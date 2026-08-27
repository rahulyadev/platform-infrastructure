output "secret_arn" {
  description = "Non-secret ARN for later least-privilege runtime wiring."
  value       = aws_secretsmanager_secret.reference_bff_client.arn
}
