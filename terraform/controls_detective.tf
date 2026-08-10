###############################################################################
# DETECTIVE CLOUD CONTROLS
#
#  1. GuardDuty              - threat detection on VPC flow logs, DNS, CloudTrail
#  2. AWS Config + rules     - continuous compliance checks that should FAIL
#                              loudly against the intentional misconfigurations
#  3. CloudWatch metric filters + alarms on the CloudTrail log group
#
# Expect these to fire. A clean dashboard here would mean the exercise failed.
###############################################################################

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-security-alerts"
  tags = local.tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- 1. GuardDuty ------------------------------------------------------------

resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = local.tags
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${local.name}-guardduty-findings"
  description = "Route GuardDuty findings of severity Medium and above to SNS"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn
}

data "aws_iam_policy_document" "sns_publish" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_publish.json
}

# --- 2. AWS Config -----------------------------------------------------------

resource "aws_s3_bucket" "config" {
  bucket        = "${local.name}-config-${random_id.bucket.hex}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "${local.name}-config-recorder"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_s3" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
  }
}

resource "aws_iam_role_policy" "config_s3" {
  name   = "config-delivery"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_s3.json
}

resource "aws_config_configuration_recorder" "this" {
  name     = "${local.name}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "${local.name}-channel"
  s3_bucket_name = aws_s3_bucket.config.id
  depends_on     = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

locals {
  config_rules = {
    # Should flag the MongoDB backup bucket.
    s3-bucket-public-read-prohibited = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    s3-bucket-public-write-prohibited = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
    # Should flag the MongoDB VM security group.
    restricted-ssh = "INCOMING_SSH_DISABLED"
    # Should flag the AdministratorAccess attachment on the VM role.
    iam-policy-no-statements-with-admin-access = "IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS"
    # Confirms the preventative controls are holding.
    ec2-imdsv2-check       = "EC2_IMDSV2_CHECK"
    encrypted-volumes      = "ENCRYPTED_VOLUMES"
    cloud-trail-enabled    = "CLOUD_TRAIL_ENABLED"
    guardduty-enabled-centralized = "GUARDDUTY_ENABLED_CENTRALIZED"
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = local.config_rules

  name = "${local.name}-${each.key}"

  source {
    owner             = "AWS"
    source_identifier = each.value
  }

  depends_on = [aws_config_configuration_recorder_status.this]
  tags       = local.tags
}

# Non-compliant Config findings go to the same SNS topic.
resource "aws_cloudwatch_event_rule" "config_noncompliance" {
  name        = "${local.name}-config-noncompliance"
  description = "Alert when an AWS Config rule evaluates as NON_COMPLIANT"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]
    detail = {
      messageType = ["ComplianceChangeNotification"]
      newEvaluationResult = {
        complianceType = ["NON_COMPLIANT"]
      }
    }
  })

  tags = local.tags
}

resource "aws_cloudwatch_event_target" "config_to_sns" {
  rule      = aws_cloudwatch_event_rule.config_noncompliance.name
  target_id = "sns"
  arn       = aws_sns_topic.alerts.arn
}

# --- 3. CloudWatch metric filters on CloudTrail ------------------------------

locals {
  metric_filters = {
    unauthorized-api-calls = {
      pattern     = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
      description = "Unauthorized API calls, a common signal of credential misuse"
    }
    root-account-usage = {
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      description = "Any use of the account root identity"
    }
    security-group-changes = {
      pattern     = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = CreateSecurityGroup) || ($.eventName = DeleteSecurityGroup) }"
      description = "Network exposure changes"
    }
    iam-policy-changes = {
      pattern     = "{ ($.eventName = AttachRolePolicy) || ($.eventName = PutRolePolicy) || ($.eventName = CreatePolicyVersion) || ($.eventName = AttachUserPolicy) }"
      description = "Privilege escalation via IAM policy changes"
    }
    anonymous-s3-access = {
      pattern     = "{ ($.userIdentity.accountId = \"anonymous\") || ($.userIdentity.type = \"AWSAccount\" && $.eventSource = \"s3.amazonaws.com\" && $.errorCode NOT EXISTS && $.userIdentity.principalId = \"ANONYMOUS_PRINCIPAL\") }"
      description = "Anonymous read of the public MongoDB backup bucket"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "this" {
  for_each = local.metric_filters

  name           = "${local.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = "${local.name}-${each.key}"
    namespace = "${local.name}/SecurityMetrics"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.metric_filters

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = "${local.name}/SecurityMetrics"
  metric_name         = "${local.name}-${each.key}"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = local.tags
}
