variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
}

variable "availability_zone" {
  description = "Primary AZ. Hosts the first public subnet (NAT GW lives here) and the single private subnet (Splunk EC2)."
  type        = string
}

variable "availability_zone_b" {
  description = "Second AZ. Hosts the second public subnet purely to satisfy the ALB's two-AZ requirement; no compute lives here."
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR for the first public subnet (NAT + IGW + ALB ENI)."
  type        = string
}

variable "public_subnet_b_cidr" {
  description = "CIDR for the second public subnet (ALB ENI in the secondary AZ)."
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
