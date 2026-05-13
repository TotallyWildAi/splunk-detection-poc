variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the ALB lives in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs the ALB attaches to. Must span at least two AZs (ALB requirement)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "ALB requires at least two public subnets in different AZs."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR. Reserved for future SG rules — not currently used directly (the Splunk SG ingress references the ALB SG)."
  type        = string
}

variable "splunk_instance_id" {
  description = "EC2 instance ID of the Splunk host to register in the target group."
  type        = string
}

variable "splunk_sg_id" {
  description = "Security group attached to the Splunk EC2. The ALB module adds an ingress rule allowing 8000/tcp from the ALB SG."
  type        = string
}

variable "hostname" {
  description = "Full FQDN that fronts Splunk Web (e.g. splunk-poc.totallywild.ai). Must be inside the Cloudflare zone."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the application DNS record + ACM validation records."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
