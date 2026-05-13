# CloudTrail → S3 → SQS ingestion plumbing for Splunk TA-aws.
#
# Flow:
#   Account-wide CloudTrail (multi-region, management events)
#     -> S3 bucket (encrypted, lifecycle-expired after N days)
#       -> S3 event notification on s3:ObjectCreated:*
#         -> SQS queue
#           -> Splunk_TA_aws "SQS-Based S3" input polls the queue,
#              fetches each new object, and indexes events as
#              sourcetype=aws:cloudtrail into Splunk.
#
# Management events on the first trail in an account are free; data events
# (S3 object-level, Lambda invoke) are NOT enabled here.
#
# The Splunk EC2 instance role gets an inline policy granting:
#   - s3:GetObject + s3:ListBucket on the trail bucket
#   - sqs:ReceiveMessage + DeleteMessage + GetQueueAttributes + GetQueueUrl
#     on the queue
# so TA-aws can authenticate via the instance profile (no static keys).

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Bucket name is account+prefix scoped, lowercase, no underscores.
  bucket_name = "${var.name_prefix}-cloudtrail-${local.account_id}"
  queue_name  = "${var.name_prefix}-cloudtrail-events"
  trail_name  = "${var.name_prefix}-trail"
}

# ─── S3 bucket holding CloudTrail objects ──────────────────────────────
resource "aws_s3_bucket" "trail" {
  bucket = local.bucket_name
  tags   = merge(var.tags, { Name = local.bucket_name })

  # POC convenience: allow Terraform to destroy the bucket even if it has
  # objects in it. Production should leave this default (false) so an
  # accidental destroy doesn't drop forensic data.
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-trail-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# Bucket policy required by CloudTrail to write its objects + check ACL.
data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${local.account_id}:trail/${local.trail_name}"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${local.account_id}:trail/${local.trail_name}"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

# ─── SQS queue receiving S3 event notifications ────────────────────────
# Splunk TA-aws (SQS-Based S3 input) polls this queue, reads each notification
# message, fetches the referenced S3 object, and parses out the CloudTrail
# events. ReceiveMessage→DeleteMessage on the TA side; we just provision the
# queue and grant the perms.
resource "aws_sqs_queue" "trail" {
  name                       = local.queue_name
  message_retention_seconds  = 345600 # 4 days
  visibility_timeout_seconds = 300    # Long enough for TA-aws to GET the S3 object + index
  sqs_managed_sse_enabled    = true

  tags = merge(var.tags, { Name = local.queue_name })
}

# Allow S3 to send messages to the queue (the bucket-notification wiring
# requires this policy be in place first).
data "aws_iam_policy_document" "queue" {
  statement {
    sid    = "AllowS3SendMessage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.trail.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.trail.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "trail" {
  queue_url = aws_sqs_queue.trail.id
  policy    = data.aws_iam_policy_document.queue.json
}

# ─── S3 → SQS event notification ───────────────────────────────────────
resource "aws_s3_bucket_notification" "trail" {
  bucket = aws_s3_bucket.trail.id

  queue {
    queue_arn = aws_sqs_queue.trail.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.trail]
}

# ─── CloudTrail ────────────────────────────────────────────────────────
# Multi-region trail capturing management events for all services. Data
# events (S3 object reads, Lambda invokes) intentionally NOT included —
# they're billable and not needed for this POC's detections.
resource "aws_cloudtrail" "this" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.trail.id

  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  tags = merge(var.tags, { Name = local.trail_name })

  depends_on = [aws_s3_bucket_policy.trail]
}

# ─── Splunk EC2 role: read perms on bucket + queue ─────────────────────
data "aws_iam_policy_document" "splunk_read" {
  statement {
    sid       = "ReadTrailObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.trail.arn}/*"]
  }

  statement {
    sid       = "ListTrailBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.trail.arn]
  }

  statement {
    sid    = "ConsumeQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
      "sqs:ListQueues",
    ]
    resources = [aws_sqs_queue.trail.arn]
  }
}

resource "aws_iam_role_policy" "splunk_cloudtrail_read" {
  name   = "${var.name_prefix}-cloudtrail-read"
  role   = var.splunk_role_name
  policy = data.aws_iam_policy_document.splunk_read.json
}
