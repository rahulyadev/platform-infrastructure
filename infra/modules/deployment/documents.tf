locals {
  document_names = {
    configure = "${var.name_prefix}-configure-runtime"
    deploy    = "${var.name_prefix}-deploy-portfolio"
    rollback  = "${var.name_prefix}-rollback-portfolio"
    tls       = "${var.name_prefix}-enable-tls"
  }
}

resource "aws_ssm_document" "configure_runtime" {
  name            = local.document_names.configure
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Configure the exact production web runtime without issuing a certificate."
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "configureRuntime"
      inputs = {
        timeoutSeconds = "1800"
        runCommand     = [var.configure_runtime_script]
      }
    }]
  })

  tags = var.tags
}

resource "aws_ssm_document" "deploy_portfolio" {
  name            = local.document_names.deploy
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Verify and atomically deploy one immutable portfolio artifact."
    parameters = {
      ArtifactBucket = {
        type              = "String"
        default           = var.artifact_bucket_name
        allowedPattern    = "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
        allowedValues     = [var.artifact_bucket_name]
        interpolationType = "ENV_VAR"
      }
      ArtifactKey = {
        type              = "String"
        allowedPattern    = "^portfolio/[A-Za-z0-9][A-Za-z0-9._/-]{0,500}[A-Za-z0-9]$"
        interpolationType = "ENV_VAR"
      }
      ArtifactSHA256 = {
        type              = "String"
        allowedPattern    = "^[0-9a-f]{64}$"
        interpolationType = "ENV_VAR"
      }
      ManifestKey = {
        type              = "String"
        allowedPattern    = "^portfolio/[A-Za-z0-9][A-Za-z0-9._/-]{0,500}[A-Za-z0-9]$"
        interpolationType = "ENV_VAR"
      }
      ManifestSHA256 = {
        type              = "String"
        allowedPattern    = "^[0-9a-f]{64}$"
        interpolationType = "ENV_VAR"
      }
      ReleaseID = {
        type              = "String"
        allowedPattern    = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deployPortfolio"
      inputs = {
        timeoutSeconds = "1800"
        runCommand     = [var.deploy_portfolio_script]
      }
    }]
  })

  tags = var.tags
}

resource "aws_ssm_document" "rollback_portfolio" {
  name            = local.document_names.rollback
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Verify and atomically activate one retained immutable portfolio release."
    parameters = {
      TargetReleaseID = {
        type              = "String"
        allowedPattern    = "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "rollbackPortfolio"
      inputs = {
        timeoutSeconds = "900"
        runCommand     = [var.rollback_portfolio_script]
      }
    }]
  })

  tags = var.tags
}

resource "aws_ssm_document" "enable_tls" {
  name            = local.document_names.tls
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Validate DNS, perform staging and production ACME issuance, and enable TLS."
    parameters = {
      BaseDomain = {
        type              = "String"
        default           = var.base_domain
        allowedPattern    = "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$"
        allowedValues     = [var.base_domain]
        interpolationType = "ENV_VAR"
      }
      AcmeEmail = {
        type              = "String"
        allowedPattern    = "^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$"
        interpolationType = "ENV_VAR"
      }
      ExpectedElasticIP = {
        type              = "String"
        default           = var.expected_elastic_ip
        allowedPattern    = "^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)){3}$"
        allowedValues     = [var.expected_elastic_ip]
        interpolationType = "ENV_VAR"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "enableTls"
      inputs = {
        timeoutSeconds = "3600"
        runCommand     = [var.enable_tls_script]
      }
    }]
  })

  tags = var.tags
}

resource "aws_ssm_association" "configure_runtime" {
  name             = aws_ssm_document.configure_runtime.name
  document_version = aws_ssm_document.configure_runtime.latest_version
  association_name = "${var.name_prefix}-configure-runtime"

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }

  wait_for_success_timeout_seconds = 1800

  tags = var.tags
}
