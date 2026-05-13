# GitHub Actions OIDC trust — lets a workflow in
# ${var.github_owner}/${var.github_repo} assume an IAM role in this account
# without static AWS access keys.
#
# Two pieces:
#   1. The IAM OIDC identity provider for token.actions.githubusercontent.com
#      (one per AWS account). If your account already has one (e.g. provisioned
#      by another repo — agent-observability already created one in this
#      account), keep create_github_oidc_provider = false (the default) and
#      pass the existing ARN via github_oidc_provider_arn_existing.
#   2. An IAM role assumable only by workflows running in the configured repo,
#      attached to AdministratorAccess.
#
# Note on thumbprints: GitHub no longer requires the thumbprint to be pinned —
# AWS added GitHub's CAs to its trust store and the value is effectively
# ignored at runtime. However, the Terraform resource still requires
# thumbprint_list to be non-empty. We supply the two historically-published
# values so the resource validates and old SDKs / off-the-beaten-path STS
# clients continue to work.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = local.common_tags
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.github_oidc_provider_arn_existing
}

data "aws_iam_policy_document" "gha_deploy_assume" {
  statement {
    sid     = "AllowGitHubActionsOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "${local.name_prefix}-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_assume.json
  tags               = local.common_tags
}

# AdministratorAccess is acceptable here because the role's trust policy is
# repo-scoped (only workflows in ${var.github_owner}/${var.github_repo} can
# assume it). For production deployments, scope this down to the specific
# AWS APIs Terraform needs (EC2, IAM, VPC, Secrets Manager, Scheduler,
# S3 state bucket, etc.).
resource "aws_iam_role_policy_attachment" "gha_deploy_admin" {
  role       = aws_iam_role.gha_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
