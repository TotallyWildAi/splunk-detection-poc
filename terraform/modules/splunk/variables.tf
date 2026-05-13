variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used in cloud-init for secretsmanager calls)."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the Splunk security group."
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet ID to launch the Splunk EC2 in (no public IP)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB (gp3)."
  type        = number
}

variable "splunk_admin_email" {
  description = "Splunk admin username (email)."
  type        = string
}

variable "splunk_deb_url" {
  description = "Direct download URL for the Splunk Enterprise .deb installer."
  type        = string
}

variable "splunk_version" {
  description = "Splunk version (informational tag)."
  type        = string
}

variable "cloudflared_image" {
  description = "cloudflared Docker image (pinned)."
  type        = string
}

variable "tunnel_token_secret_arn" {
  description = "Secrets Manager ARN holding the Cloudflare Tunnel token."
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name. Passed in from the root module so the secrets policy can be co-located with the role definition."
  type        = string
}

variable "apps_s3_bucket" {
  description = "S3 bucket containing Splunk app packages to install at boot."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
