output "splunk_url" {
  description = "Public Splunk Web URL fronted by the ALB."
  value       = "https://${var.hostname}"
}

output "alb_dns_name" {
  description = "ALB DNS name (the Cloudflare CNAME points at this)."
  value       = aws_lb.this.dns_name
}

output "alb_sg_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}
