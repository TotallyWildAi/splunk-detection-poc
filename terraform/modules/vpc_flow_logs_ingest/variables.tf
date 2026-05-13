variable "name_prefix" {
  description = "Prefix applied to all resource names in this module."
  type        = string
}

variable "aws_region" {
  description = "Region where the VPC, bucket, and queue live."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC to enable flow logs on. Comes from module.vpc.vpc_id."
  type        = string
}

variable "splunk_role_name" {
  description = "Name of the existing Splunk EC2 IAM role. This module attaches an inline policy granting S3 + SQS read access for TA-aws."
  type        = string
}

variable "retention_days" {
  description = "Number of days to retain flow log objects in the bucket before lifecycle expiration. Flow logs are for live detection ingestion — Splunk indexes them, so keeping much history in S3 is redundant."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
