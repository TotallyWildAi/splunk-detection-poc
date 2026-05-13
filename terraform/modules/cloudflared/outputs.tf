output "tunnel_id" {
  description = "Cloudflare Tunnel ID."
  value       = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_token_secret_arn" {
  description = "Secrets Manager ARN holding the tunnel token. Consumed by the cloudflared sidecar on the Splunk EC2 host."
  value       = aws_secretsmanager_secret.tunnel_token.arn
}

output "splunk_url" {
  description = "Public Splunk Web URL fronted by Cloudflare Access."
  value       = "https://${var.splunk_web_hostname}"
}

output "hec_url" {
  description = "Public Splunk HEC URL fronted by Cloudflare Access."
  value       = "https://${var.splunk_hec_hostname}"
}

output "access_application_id" {
  description = "Cloudflare Access application ID."
  value       = cloudflare_zero_trust_access_application.splunk.id
}
