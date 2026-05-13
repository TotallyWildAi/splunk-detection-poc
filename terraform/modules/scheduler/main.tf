# EventBridge Scheduler — business-hours start/stop for the Splunk EC2.
#
# Uses the modern aws_scheduler_schedule resource (the dedicated Scheduler
# service), NOT the legacy aws_cloudwatch_event_rule. Two schedules: one
# fires ec2:StartInstances, one fires ec2:StopInstances. Both run in the
# var.timezone IANA zone. Gated by var.enabled — false flips both schedules
# to DISABLED without recreating anything.

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = var.tags
}

# Scoped to the specific instance ARN — no wildcard. ec2:StartInstances /
# StopInstances on a specific instance is least-privilege for this job.
data "aws_iam_policy_document" "scheduler" {
  statement {
    sid = "StartStopSplunkInstance"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
    ]
    resources = [var.instance_arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${var.name_prefix}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# ─── Schedules ─────────────────────────────────────────────────────────

resource "aws_scheduler_schedule" "start" {
  name        = "${var.name_prefix}-start"
  description = "Start the Splunk POC EC2 at the configured business-hours time."
  state       = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.start_cron
  schedule_expression_timezone = var.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [var.instance_id]
    })
  }
}

resource "aws_scheduler_schedule" "stop" {
  name        = "${var.name_prefix}-stop"
  description = "Stop the Splunk POC EC2 at the configured business-hours time."
  state       = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.stop_cron
  schedule_expression_timezone = var.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = [var.instance_id]
    })
  }
}
