output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_id" {
  description = "Public subnet ID."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet ID."
  value       = aws_subnet.private.id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID."
  value       = aws_nat_gateway.this.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID."
  value       = aws_internet_gateway.this.id
}
