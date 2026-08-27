locals {
  identity_api_repository_url = aws_ecr_repository.identity["${var.name_prefix}-identity-api"].repository_url
  identity_bff_repository_url = aws_ecr_repository.identity["${var.name_prefix}-identity-bff"].repository_url
  identity_ecr_registry       = split("/", local.identity_api_repository_url)[0]

  rendered_document_scripts = {
    for key, script in var.document_scripts : key => replace(
      replace(
        replace(script, "__IDENTITY_API_REPOSITORY_URL__", local.identity_api_repository_url),
        "__IDENTITY_BFF_REPOSITORY_URL__", local.identity_bff_repository_url
      ),
      "__IDENTITY_ECR_REGISTRY__", local.identity_ecr_registry
    )
  }

  document_names = {
    configure = "${var.name_prefix}-configure-identity-runtime"
    deploy    = "${var.name_prefix}-migrate-deploy-identity"
    tls       = "${var.name_prefix}-enable-identity-tls"
    verify    = "${var.name_prefix}-verify-identity"
    rollback  = "${var.name_prefix}-rollback-identity"
    backup    = "${var.name_prefix}-backup-identity"
    restore   = "${var.name_prefix}-restore-identity"
  }


  document_parameters = {
    configure = {}
    deploy = {
      releaseId = {
        type              = "String"
        description       = "Immutable release identifier"
        allowedPattern    = "^[a-z0-9][a-z0-9._-]{0,63}$"
        interpolationType = "ENV_VAR"
      }
      apiImage = {
        type              = "String"
        description       = "Immutable Identity API image"
        allowedPattern    = "^${replace(local.identity_api_repository_url, ".", "[.]")}@sha256:[0-9a-f]{64}$"
        interpolationType = "ENV_VAR"
      }
      bffImage = {
        type              = "String"
        description       = "Immutable reference-BFF image"
        allowedPattern    = "^${replace(local.identity_bff_repository_url, ".", "[.]")}@sha256:[0-9a-f]{64}$"
        interpolationType = "ENV_VAR"
      }
      issuer = {
        type              = "String"
        description       = "Exact regional Cognito issuer"
        allowedPattern    = "^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+$"
        interpolationType = "ENV_VAR"
      }
      jwksUri = {
        type              = "String"
        description       = "Exact Cognito JWKS URI"
        allowedPattern    = "^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+/[.]well-known/jwks[.]json$"
        interpolationType = "ENV_VAR"
      }
      clientId = {
        type              = "String"
        description       = "Non-secret Cognito app-client identifier"
        allowedPattern    = "^[a-z0-9]{26}$"
        interpolationType = "ENV_VAR"
      }
    }
    tls = {
      identityDomain = {
        type              = "String"
        description       = "Exact externally managed Identity API DNS name"
        allowedValues     = ["identity.rahuly.in"]
        interpolationType = "ENV_VAR"
      }
      expectedElasticIp = {
        type              = "String"
        description       = "Reviewed production Elastic IPv4 address"
        allowedPattern    = "^(?:[0-9]{1,3}[.]){3}[0-9]{1,3}$"
        interpolationType = "ENV_VAR"
      }
      acmeEmail = {
        type              = "String"
        description       = "ACME registration email"
        allowedPattern    = "^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}$"
        interpolationType = "ENV_VAR"
      }
    }
    verify   = {}
    rollback = {}
    backup = {
      backupType = {
        type              = "String"
        description       = "Reviewed full or differential backup type"
        default           = "diff"
        allowedValues     = ["full", "diff"]
        interpolationType = "ENV_VAR"
      }
    }
    restore = {
      recoveryTarget = {
        type              = "String"
        description       = "ISO-8601 recovery target or immediate"
        default           = "immediate"
        allowedPattern    = "^(immediate|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$"
        interpolationType = "ENV_VAR"
      }
    }
  }
}

resource "aws_ssm_document" "identity" {
  for_each = local.document_names

  name            = each.value
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Reviewed fixed ${each.key} Identity production operation"
    parameters    = local.document_parameters[each.key]
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "identity${title(each.key)}"
      inputs = {
        timeoutSeconds = "3600"
        runCommand     = [local.rendered_document_scripts[each.key]]
      }
    }]
  })

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssm_association" "configure_identity_runtime" {
  count = var.enable_runtime ? 1 : 0

  name             = aws_ssm_document.identity["configure"].name
  association_name = "${var.name_prefix}-configure-identity-runtime"

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }
}

resource "aws_ssm_association" "identity_backup_diff" {
  count = var.enable_runtime ? 1 : 0

  name                        = aws_ssm_document.identity["backup"].name
  association_name            = "${var.name_prefix}-identity-backup-diff"
  apply_only_at_cron_interval = true
  schedule_expression         = "cron(0 2 ? * MON-SAT *)"

  parameters = {
    backupType = "diff"
  }

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }
}

resource "aws_ssm_association" "identity_backup_full" {
  count = var.enable_runtime ? 1 : 0

  name                        = aws_ssm_document.identity["backup"].name
  association_name            = "${var.name_prefix}-identity-backup-full"
  apply_only_at_cron_interval = true
  schedule_expression         = "cron(0 2 ? * SUN *)"

  parameters = {
    backupType = "full"
  }

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }
}

resource "aws_ssm_association" "verify_identity" {
  count = var.enable_runtime ? 1 : 0

  name                        = aws_ssm_document.identity["verify"].name
  association_name            = "${var.name_prefix}-verify-identity"
  apply_only_at_cron_interval = true
  schedule_expression         = "rate(30 minutes)"

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }
}
