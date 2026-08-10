###############################################################################
# PREVENTATIVE CLOUD CONTROLS
#
# These stop a bad state from ever being created, as opposed to detecting it
# after the fact. The exercise asks for at least one; four are implemented.
#
#  1. Account-wide EBS encryption by default   (this file)
#  2. IAM permissions boundary that denies the destruction of audit logging
#     and denies disabling the public-access-block on the CloudTrail bucket
#     (this file)
#  3. Account password policy                  (this file)
#  4. IMDSv2 required on all EC2 instances     (mongodb_vm.tf, eks.tf)
#  5. Public access block on the CloudTrail bucket (logging_cloudtrail.tf)
###############################################################################

# 1. Every new EBS volume in this region is encrypted whether or not the
#    requester asks for it. Nothing can opt out.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# 3. Baseline IAM password policy for any console users in the account.
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 12
}

# 2. Permissions boundary. Attach this to any role you create for humans or
#    automation in the exercise account: it grants nothing by itself, it only
#    caps what an attached policy can ever authorise.
data "aws_iam_policy_document" "guardrail_boundary" {
  statement {
    sid       = "AllowEverythingElse"
    effect    = "Allow"
    actions   = ["*"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyTamperingWithAuditLogging"
    effect = "Deny"
    actions = [
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "config:DeleteConfigurationRecorder",
      "config:StopConfigurationRecorder",
      "config:DeleteDeliveryChannel",
      "guardduty:DeleteDetector",
      "guardduty:DisassociateFromMasterAccount",
      "guardduty:UpdateDetector"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyExposingTheAuditLogBucket"
    effect = "Deny"
    actions = [
      "s3:PutBucketPublicAccessBlock",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketAcl"
    ]
    resources = [
      aws_s3_bucket.trail.arn,
      "${aws_s3_bucket.trail.arn}/*"
    ]
  }

  statement {
    sid       = "DenyDeletingAuditLogObjects"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.trail.arn}/*"]
  }
}

resource "aws_iam_policy" "guardrail_boundary" {
  name        = "${local.name}-permissions-boundary"
  description = "Preventative guardrail: audit logging and its bucket cannot be tampered with or exposed."
  policy      = data.aws_iam_policy_document.guardrail_boundary.json
  tags        = local.tags
}

# Demonstration: a role that carries AdministratorAccess but is capped by the
# boundary, so it still cannot stop CloudTrail. Compare with the MongoDB VM
# role in mongodb_vm.tf, which has no boundary at all.
data "aws_iam_policy_document" "break_glass_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "bounded_admin" {
  name                 = "${local.name}-bounded-admin"
  assume_role_policy   = data.aws_iam_policy_document.break_glass_assume.json
  permissions_boundary = aws_iam_policy.guardrail_boundary.arn
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "bounded_admin" {
  role       = aws_iam_role.bounded_admin.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}
