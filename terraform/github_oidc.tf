###############################################################################
# GitHub Actions authentication via OIDC.
#
# No long-lived AWS access keys are ever stored in GitHub. Actions exchanges a
# short-lived OIDC token for temporary credentials, and the trust policy is
# scoped to this repository (and to specific refs for the apply role).
#
# Bootstrap order: run `terraform apply` once from your workstation to create
# these roles, then add their ARNs as repository variables and let the
# pipelines take over.
###############################################################################

variable "github_repository" {
  description = "GitHub repo allowed to assume the deploy roles, as owner/name."
  type        = string
}

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  tags            = local.tags
}

# --- Plan/scan role: read-only, usable from pull requests --------------------

data "aws_iam_policy_document" "gha_plan_assume" {
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "gha_plan" {
  name               = "${local.name}-gha-plan"
  assume_role_policy = data.aws_iam_policy_document.gha_plan_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

# --- Apply role: privileged, restricted to the default branch ----------------

data "aws_iam_policy_document" "gha_apply_assume" {
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
    # Only workflows running on the main branch, or in the "production"
    # environment, can assume the privileged role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:environment:production"
      ]
    }
  }
}

resource "aws_iam_role" "gha_apply" {
  name               = "${local.name}-gha-apply"
  assume_role_policy = data.aws_iam_policy_document.gha_apply_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "gha_apply_admin" {
  role       = aws_iam_role.gha_apply.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# --- App deploy role: ECR push + kubectl only --------------------------------

data "aws_iam_policy_document" "gha_app_assume" {
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:environment:production"
      ]
    }
  }
}

resource "aws_iam_role" "gha_app" {
  name               = "${local.name}-gha-app-deploy"
  assume_role_policy = data.aws_iam_policy_document.gha_app_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "gha_app" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings"
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "EksDescribeForKubeconfig"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "gha_app" {
  name   = "app-deploy"
  role   = aws_iam_role.gha_app.id
  policy = data.aws_iam_policy_document.gha_app.json
}

# Grant that role rights inside the cluster, scoped to the app namespace.
resource "aws_eks_access_entry" "gha_app" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gha_app.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gha_app" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.gha_app.arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [kubernetes_namespace_v1.app.metadata[0].name]
  }
}

output "github_actions_plan_role_arn" {
  value = aws_iam_role.gha_plan.arn
}

output "github_actions_apply_role_arn" {
  value = aws_iam_role.gha_apply.arn
}

output "github_actions_app_role_arn" {
  value = aws_iam_role.gha_app.arn
}
