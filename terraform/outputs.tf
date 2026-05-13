output "deployment_summary" {
  description = "Summary of where this stack is deployed."
  value = {
    region         = var.aws_region
    vpc_id         = module.vpc.vpc_id
    splunk_version = var.splunk_version
    name_prefix    = var.name_prefix
    environment    = var.environment_name
  }
}

output "splunk_url" {
  description = "Splunk Web URL (fronted by the public ALB, HTTPS via ACM)."
  value       = module.alb.splunk_url
}

output "alb_dns_name" {
  description = "ALB DNS name. The Cloudflare CNAME for splunk_web_hostname resolves to this."
  value       = module.alb.alb_dns_name
}

output "splunk_admin_email" {
  description = "Splunk admin login (username field)."
  value       = var.splunk_admin_email
}

output "splunk_admin_password_secret_arn" {
  description = "Secrets Manager ARN holding the auto-generated Splunk admin password."
  value       = module.splunk.admin_password_secret_arn
}

output "splunk_instance_id" {
  description = "EC2 instance ID hosting Splunk. Use this with `aws ssm start-session --target ...` for shell access."
  value       = module.splunk.instance_id
}

output "splunk_private_ip" {
  description = "Private IP of the Splunk EC2 instance (reachable only from inside the VPC)."
  value       = module.splunk.private_ip
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC. Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.gha_deploy.arn
}

output "splunk_apps_bucket" {
  description = "S3 bucket name holding the Splunk app packages. Objects are NOT managed by Terraform — sync them via scripts/sync-apps.sh."
  value       = aws_s3_bucket.splunk_apps.bucket
}

# ─── CloudTrail ingestion (Phase 2.1) ──────────────────────────────────
output "cloudtrail_bucket" {
  description = "S3 bucket receiving CloudTrail logs (Splunk TA-aws reads from here via SQS notifications)."
  value       = module.cloudtrail_ingest.bucket_name
}

output "cloudtrail_queue_url" {
  description = "SQS queue URL — configure this as the queue for the Splunk_TA_aws 'SQS-Based S3' input."
  value       = module.cloudtrail_ingest.queue_url
}

output "cloudtrail_queue_name" {
  description = "SQS queue name (bare name) — TA-aws often wants the name, not the URL."
  value       = module.cloudtrail_ingest.queue_name
}
