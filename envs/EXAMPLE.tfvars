# Copy this file to <env>.tfvars (gitignored) and fill in env-specific values.
#
# Example deploy:
#   export CLOUDFLARE_API_TOKEN=...        # required — read by the cloudflare provider
#   cd terraform
#   terraform init -backend-config=../envs/<env>.backend.hcl
#   terraform apply -var-file=../envs/<env>.tfvars
#
# CLOUDFLARE_API_TOKEN must be exported before `terraform plan` / `terraform apply`.
# Token scope: Zone → DNS: Edit on the target zone (DNS-only — no Tunnel /
# Access scopes needed after the ALB refactor).

# ---- Required (AWS) ----
aws_region           = "ap-southeast-2"
vpc_cidr             = "10.2.0.0/16"
availability_zone    = "ap-southeast-2a"
availability_zone_b  = "ap-southeast-2b"
public_subnet_cidr   = "10.2.0.0/24"
public_subnet_b_cidr = "10.2.2.0/24"
private_subnet_cidr  = "10.2.1.0/24"

# ---- Splunk EC2 ----
splunk_instance_type       = "m5.xlarge"
splunk_root_volume_size_gb = 200
splunk_admin_email         = "admin@example.com"
# splunk_deb_url           = "https://download.splunk.com/products/splunk/releases/10.2.3/linux/splunk-10.2.3-4d61cf8a5c0c-linux-amd64.deb"
# splunk_version           = "10.2.3"

# ---- Required (Cloudflare DNS — used for the ALB CNAME + ACM validation) ----
cloudflare_zone_id   = "0000000000000000000000000000000000"
cloudflare_zone_name = "example.com"
splunk_web_hostname  = "splunk-poc.example.com"

# ---- Scheduler (business hours start/stop) ----
# scheduler_enabled  = true
# scheduler_timezone = "Australia/Sydney"
# scheduler_start_cron = "cron(0 9 ? * MON-FRI *)"
# scheduler_stop_cron  = "cron(0 18 ? * MON-FRI *)"

# ---- Naming & tags ----
# name_prefix      = "splunk-poc"
# environment_name = "test"
# common_tags      = { CostCenter = "platform" }

# ---- GitHub Actions OIDC ----
# Default assumes the OIDC provider already exists in this account (from
# agent-observability). Override for a fresh account.
# create_github_oidc_provider       = false
# github_oidc_provider_arn_existing = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com"
