data "aws_iam_policy_document" "github_deployer" {
  statement {
    sid       = "ListPortfolioArtifacts"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.artifact_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["portfolio/*"]
    }
  }

  statement {
    sid    = "WriteImmutablePortfolioArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${var.artifact_bucket_arn}/portfolio/*"]
  }

  statement {
    sid     = "RunFixedDeploymentDocuments"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_ssm_document.deploy_portfolio.arn,
      aws_ssm_document.rollback_portfolio.arn,
      var.instance_arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # These read APIs do not support resource-level permissions. The requested
  # region condition prevents cross-region discovery or command polling.
  statement {
    sid    = "PollDeploymentAndDiscoverTarget"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "github_deployer" {
  name   = "${var.name_prefix}-deployment"
  role   = aws_iam_role.github_deployer.id
  policy = data.aws_iam_policy_document.github_deployer.json
}
