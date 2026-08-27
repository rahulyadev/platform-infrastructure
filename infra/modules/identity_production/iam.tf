data "aws_iam_policy_document" "github_identity_deployer" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PublishIdentityImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for repository in aws_ecr_repository.identity : repository.arn]
  }

  statement {
    sid    = "RunReviewedIdentityDocuments"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = concat(
      ["arn:aws:ec2:${var.aws_region}:${var.expected_account_id}:instance/${var.instance_id}"],
      [for key in ["deploy", "verify", "rollback"] : aws_ssm_document.identity[key].arn],
    )
  }

  statement {
    sid    = "ObserveIdentityCommands"
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_identity_deployer" {
  name   = "${var.name_prefix}-identity-deployer"
  role   = aws_iam_role.github_identity_deployer.id
  policy = data.aws_iam_policy_document.github_identity_deployer.json
}

data "aws_iam_policy_document" "host_identity_runtime" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullIdentityImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for repository in aws_ecr_repository.identity : repository.arn]
  }

  statement {
    sid       = "ReadIdentityRuntimeSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = sort(tolist(var.runtime_secret_arns))
  }

  statement {
    sid       = "ListIdentityBackups"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.backup_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["identity/production/*"]
    }
  }

  statement {
    sid    = "IdentityBackupObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${var.backup_bucket_arn}/identity/production/*"]
  }

  statement {
    sid       = "PublishIdentityMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["PlatformInfrastructure/Production/Identity"]
    }
  }

  statement {
    sid    = "WriteIdentityLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [for log_group in aws_cloudwatch_log_group.identity : "${log_group.arn}:*"]
  }
}

resource "aws_iam_role_policy" "host_identity_runtime" {
  name   = "${var.name_prefix}-identity-runtime"
  role   = var.instance_role_name
  policy = data.aws_iam_policy_document.host_identity_runtime.json
}
