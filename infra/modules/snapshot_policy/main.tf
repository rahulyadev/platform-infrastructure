data "aws_iam_policy_document" "assume_dlm" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.name_prefix}-dlm-snapshots"
  assume_role_policy = data.aws_iam_policy_document.assume_dlm.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "production" {
  description        = "Daily and monthly production host snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]
    target_tags    = var.target_instance_tags

    parameters {
      exclude_boot_volume = false
      no_reboot           = true
    }

    schedule {
      name      = "Daily production host snapshot"
      copy_tags = true

      create_rule {
        cron_expression = "cron(0 3 * * ? *)"
      }

      retain_rule {
        count = var.daily_snapshot_retention_count
      }

      tags_to_add = merge(var.tags, {
        BackupPurpose = "daily-host-recovery"
      })
    }

    schedule {
      name      = "Monthly production host snapshot"
      copy_tags = true

      create_rule {
        cron_expression = "cron(0 4 1 * ? *)"
      }

      retain_rule {
        count = var.monthly_snapshot_retention_count
      }

      tags_to_add = merge(var.tags, {
        BackupPurpose = "monthly-host-recovery"
      })
    }
  }

  tags = var.tags
}
