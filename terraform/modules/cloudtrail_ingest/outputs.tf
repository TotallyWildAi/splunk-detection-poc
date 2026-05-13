output "trail_name" {
  description = "Name of the CloudTrail."
  value       = aws_cloudtrail.this.name
}

output "trail_arn" {
  description = "ARN of the CloudTrail."
  value       = aws_cloudtrail.this.arn
}

output "bucket_name" {
  description = "S3 bucket name receiving CloudTrail logs."
  value       = aws_s3_bucket.trail.bucket
}

output "bucket_arn" {
  description = "S3 bucket ARN receiving CloudTrail logs."
  value       = aws_s3_bucket.trail.arn
}

output "queue_url" {
  description = "SQS queue URL — paste this into Splunk_TA_aws's SQS-Based S3 input."
  value       = aws_sqs_queue.trail.url
}

output "queue_arn" {
  description = "SQS queue ARN."
  value       = aws_sqs_queue.trail.arn
}

output "queue_name" {
  description = "SQS queue name (just the name, not the URL — useful for the TA-aws UI which sometimes wants the bare name)."
  value       = aws_sqs_queue.trail.name
}
