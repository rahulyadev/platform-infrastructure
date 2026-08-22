resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = var.tags
}

locals {
  github_subject = "repo:${var.github_owner}@${format("%.0f", var.github_owner_id)}/${var.github_repository}@${format("%.0f", var.github_repository_id)}:environment:${var.github_environment}"
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "github_deployer" {
  name               = "${var.name_prefix}-deployer"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json

  tags = var.tags
}
