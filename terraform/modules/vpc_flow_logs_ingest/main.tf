# VPC Flow Logs → S3 → SQS ingestion plumbing for Splunk TA-aws.
#
# Flow:
#   VPC flow logs (traffic_type=ALL, 10-min aggregation, extended v3+ fields)
#     -> S3 bucket (encrypted, lifecycle-expired after N days)
#       -> S3 event notification on s3:ObjectCreated:*
#         -> SQS queue
#           -> Splunk_TA_aws "SQS-Based S3" input polls the queue with the
#              "VPCFlow" S3 file decoder and indexes events as
#              sourcetype=aws:cloudwatchlogs:vpcflow into Splunk.
#
# Plain-text (not parquet) format is required — the TA-aws VPCFlow decoder
# only understands the plain space-separated text layout that AWS writes
# when log_format is set without Parquet enabled.
#
# The Splunk EC2 instance role gets an inline policy granting:
#   - s3:GetObject + s3:ListBucket on the flow-logs bucket
#   - sqs:ReceiveMessage + DeleteMessage + GetQueueAttributes + GetQueueUrl
#     on the queue
# so TA-aws can authenticate via the instance profile (no static keys).

data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.name_prefix}-vpcflow-${local.account_id}"
  queue_name  = "${var.name_prefix}-vpcflow-events"

  # Extended v3+ flow log fields. v2 defaults plus the detection-useful extras:
  # vpc-id, subnet-id, instance-id, tcp-flags, type, pkt-srcaddr/dstaddr (for
  # mirrored / NAT'd traffic where srcaddr ≠ pkt-srcaddr), region, az-id,
  # sublocation-type/id (Outposts/Wavelength), pkt-src-aws-service /
  # pkt-dst-aws-service (e.g. "S3", "EC2") for quick service attribution,
  # flow-direction (ingress/egress), traffic-path (which hop forwarded it).
  #
  # The leading ${...} ${...} list is the v2 default. AWS expects fields
  # space-separated, each wrapped in ${} for substitution at delivery time.
  log_format = join(" ", [
    "$${version}",
    "$${account-id}",
    "$${interface-id}",
    "$${srcaddr}",
    "$${dstaddr}",
    "$${srcport}",
    "$${dstport}",
    "$${protocol}",
    "$${packets}",
    "$${bytes}",
    "$${start}",
    "$${end}",
    "$${action}",
    "$${log-status}",
    "$${vpc-id}",
    "$${subnet-id}",
    "$${instance-id}",
    "$${tcp-flags}",
    "$${type}",
    "$${pkt-srcaddr}",
    "$${pkt-dstaddr}",
    "$${region}",
    "$${az-id}",
    "$${sublocation-type}",
    "$${sublocation-id}",
    "$${pkt-src-aws-service}",
    "$${pkt-dst-aws-service}",
    "$${flow-direction}",
    "$${traffic-path}",
  ])
}

# ─── S3 bucket holding VPC flow log objects ────────────────────────────
resource "aws_s3_bucket" "flow" {
  bucket = local.bucket_name
  tags   = merge(var.tags, { Name = local.bucket_name })

  # POC convenience: allow Terraform to destroy the bucket even if it has
  # objects in it. Production should leave this default (false) so an
  # accidental destroy doesn't drop forensic data.
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow" {
  bucket = aws_s3_bucket.flow.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flow" {
  bucket                  = aws_s3_bucket.flow.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "flow" {
  bucket = aws_s3_bucket.flow.id

  rule {
    id     = "expire-flow-objects"
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

# Bucket policy required by the VPC flow log delivery service to write its
# objects + check ACL. delivery.logs.amazonaws.com is the principal AWS uses
# for both VPC flow logs and Route53 query logs when destination=S3.
data "aws_iam_policy_document" "flow_bucket" {
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow.arn}/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "flow" {
  bucket = aws_s3_bucket.flow.id
  policy = data.aws_iam_policy_document.flow_bucket.json
}

# ─── SQS queue receiving S3 event notifications ────────────────────────
# Splunk TA-aws (SQS-Based S3 input, "VPCFlow" decoder) polls this queue,
# reads each notification, fetches the referenced S3 object, and parses the
# space-separated flow records. ReceiveMessage→DeleteMessage on the TA side;
# we just provision the queue and grant the perms.
resource "aws_sqs_queue" "flow" {
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
    resources = [aws_sqs_queue.flow.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.flow.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "flow" {
  queue_url = aws_sqs_queue.flow.id
  policy    = data.aws_iam_policy_document.queue.json
}

# ─── S3 → SQS event notification ───────────────────────────────────────
resource "aws_s3_bucket_notification" "flow" {
  bucket = aws_s3_bucket.flow.id

  queue {
    queue_arn = aws_sqs_queue.flow.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.flow]
}

# ─── VPC flow log ──────────────────────────────────────────────────────
# traffic_type=ALL captures both ACCEPT and REJECT — REJECTs are the signal
# for most network-recon detections, ACCEPTs give the success/lateral picture.
# max_aggregation_interval=600 (10 min) is the cheaper of the two valid values
# (the other is 60s); the POC doesn't need sub-minute latency.
resource "aws_flow_log" "this" {
  vpc_id                   = var.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = aws_s3_bucket.flow.arn
  max_aggregation_interval = 600
  log_format               = local.log_format

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpcflow" })

  depends_on = [aws_s3_bucket_policy.flow]
}

# ─── Splunk EC2 role: read perms on bucket + queue ─────────────────────
data "aws_iam_policy_document" "splunk_read" {
  statement {
    sid       = "ReadFlowObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.flow.arn}/*"]
  }

  statement {
    sid       = "ListFlowBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.flow.arn]
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
    resources = [aws_sqs_queue.flow.arn]
  }
}

resource "aws_iam_role_policy" "splunk_vpcflow_read" {
  name   = "${var.name_prefix}-vpcflow-read"
  role   = var.splunk_role_name
  policy = data.aws_iam_policy_document.splunk_read.json
}
