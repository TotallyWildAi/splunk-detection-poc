variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
}

variable "availability_zone" {
  description = "Single AZ to deploy into."
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (NAT + IGW)."
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (Splunk EC2)."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}
