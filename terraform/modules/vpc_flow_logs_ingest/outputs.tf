output "bucket_name" {
  description = "S3 bucket name receiving VPC flow logs."
  value       = aws_s3_bucket.flow.bucket
}

output "bucket_arn" {
  description = "S3 bucket ARN receiving VPC flow logs."
  value       = aws_s3_bucket.flow.arn
}

output "queue_url" {
  description = "SQS queue URL — paste this into Splunk_TA_aws's SQS-Based S3 input."
  value       = aws_sqs_queue.flow.url
}

output "queue_arn" {
  description = "SQS queue ARN."
  value       = aws_sqs_queue.flow.arn
}

output "queue_name" {
  description = "SQS queue name (just the name, not the URL — useful for the TA-aws UI which sometimes wants the bare name)."
  value       = aws_sqs_queue.flow.name
}

output "flow_log_id" {
  description = "ID of the VPC flow log resource."
  value       = aws_flow_log.this.id
}
