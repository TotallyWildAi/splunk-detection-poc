variable "name_prefix" {
  description = "Prefix applied to all resource names in this module."
  type        = string
}

variable "aws_region" {
  description = "Region where the trail, bucket, and queue live."
  type        = string
}

variable "splunk_role_name" {
  description = "Name of the existing Splunk EC2 IAM role. This module attaches an inline policy granting S3 + SQS read access for TA-aws."
  type        = string
}

variable "retention_days" {
  description = "Number of days to retain CloudTrail objects in the bucket before lifecycle expiration. Trail data is for live detection ingestion — Splunk indexes it, so keeping much history in S3 is redundant."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
