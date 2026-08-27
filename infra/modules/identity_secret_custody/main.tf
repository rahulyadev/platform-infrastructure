resource "aws_secretsmanager_secret" "reference_bff_client" {
  name                    = "${var.name_prefix}/identity/reference-bff-client"
  description             = "Generated Cognito reference-BFF client secret custody."
  recovery_window_in_days = 30
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "reference_bff_client" {
  secret_id = aws_secretsmanager_secret.reference_bff_client.id
  secret_string = jsonencode({
    client_secret = var.client_secret
  })
  version_stages = ["AWSCURRENT"]

  lifecycle {
    prevent_destroy = true
  }
}
