###############################################################################
# MongoDB backup bucket
#
# INTENTIONAL MISCONFIGURATION (exercise requirement):
#   - Public Access Block fully disabled
#   - Bucket policy grants s3:GetObject and s3:ListBucket to Principal "*"
#     => anonymous read AND anonymous listing of every backup object
#
# This is the single most dangerous resource in the stack. Do not put real data
# in the database. The AWS Config rule s3-bucket-public-read-prohibited and
# GuardDuty S3 findings should both light up on this bucket, which is the point.
###############################################################################

resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "backups" {
  bucket        = "${local.name}-mongo-backups-${random_id.bucket.hex}"
  force_destroy = true

  tags = merge(local.tags, {
    Name                 = "${local.name}-mongo-backups"
    IntentionallyPublic  = "true"
    ExerciseRequirement  = "public-read-and-list"
  })
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# INTENTIONAL: every guardrail switched off.
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-backups"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

data "aws_iam_policy_document" "backups_public" {
  # Anonymous object read.
  statement {
    sid    = "PublicRead"
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }

  # Anonymous bucket listing.
  statement {
    sid    = "PublicList"
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.backups_public.json

  depends_on = [aws_s3_bucket_public_access_block.backups]
}
