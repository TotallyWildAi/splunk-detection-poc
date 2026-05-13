output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.splunk.id
}

output "instance_arn" {
  description = "EC2 instance ARN (used by the scheduler module to scope ec2:StartInstances / ec2:StopInstances)."
  value       = aws_instance.splunk.arn
}

output "private_ip" {
  description = "Private IP of the Splunk EC2 — referenced by the cloudflared tunnel ingress config."
  value       = aws_instance.splunk.private_ip
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN holding the auto-generated Splunk admin password."
  value       = aws_secretsmanager_secret.admin.arn
}

output "security_group_id" {
  description = "Security group attached to the Splunk EC2 instance."
  value       = aws_security_group.splunk.id
}
