locals {
  github_subject = "repo:${var.github_owner}/${var.github_repository}:environment:${var.github_environment}"
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_owner_id"
      values   = [tostring(var.github_owner_id)]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_id"
      values   = [tostring(var.github_repository_id)]
    }
  }
}

resource "aws_iam_role" "github_identity_deployer" {
  name               = "${var.name_prefix}-identity-deployer"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = var.tags
}
