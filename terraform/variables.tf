variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-2"
}

# ─── VPC ────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR for the dedicated Splunk POC VPC. Separate from any agent-* network."
  type        = string
  default     = "10.2.0.0/16"
}

variable "availability_zone" {
  description = "Single AZ used for the POC (one public subnet + one private subnet + one NAT)."
  type        = string
  default     = "ap-southeast-2a"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (NAT GW + IGW)."
  type        = string
  default     = "10.2.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (Splunk EC2)."
  type        = string
  default     = "10.2.1.0/24"
}

# ─── Naming / tags ──────────────────────────────────────────────────────

variable "name_prefix" {
  description = "Prefix applied to all resource names. Lets multiple deployments coexist in one account."
  type        = string
  default     = "splunk-poc"
}

variable "environment_name" {
  description = "Optional environment label applied as the `Environment` tag (e.g. dev, test, prod). Not baked into resource names."
  type        = string
  default     = "test"
}

variable "common_tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# ─── Splunk EC2 ─────────────────────────────────────────────────────────

variable "splunk_instance_type" {
  description = "EC2 instance type for the Splunk Enterprise host."
  type        = string
  default     = "m5.xlarge"
}

variable "splunk_root_volume_size_gb" {
  description = "Root EBS volume size in GB (gp3). Sized for the POC's expected ingest + index retention."
  type        = number
  default     = 200
}

variable "splunk_admin_email" {
  description = "Splunk admin username (an email address by convention). Stored in user-seed.conf during cloud-init."
  type        = string
  default     = "admin@totallywild.ai"
}

variable "splunk_deb_url" {
  description = "Direct download URL for the Splunk Enterprise .deb installer. Pinned to a specific release for reproducibility."
  type        = string
  default     = "https://download.splunk.com/products/splunk/releases/10.2.3/linux/splunk-10.2.3-4d61cf8a5c0c-linux-amd64.deb"
}

variable "splunk_version" {
  description = "Splunk version string (informational — surfaces in tags + outputs). Must match the version in splunk_deb_url."
  type        = string
  default     = "10.2.3"
}

# ─── Cloudflare (Tunnel + Access SSO) ──────────────────────────────────

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the tunnel and Access app. The CLOUDFLARE_API_TOKEN env var must be set when running terraform."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the Splunk DNS records."
  type        = string
}

variable "cloudflare_zone_name" {
  description = "Cloudflare zone name (e.g. totallywild.ai). Reference / docs only — not used by any resource."
  type        = string
}

variable "splunk_web_hostname" {
  description = "Full FQDN that fronts Splunk Web (port 8000). Must be inside cloudflare_zone_name."
  type        = string
}

variable "splunk_hec_hostname" {
  description = "Full FQDN that fronts Splunk HEC (port 8088). Must be inside cloudflare_zone_name."
  type        = string
}

variable "access_allowed_email_domains" {
  description = "Email domains permitted by Cloudflare Access. May be empty if access_allowed_emails is set."
  type        = list(string)
  default     = []
}

variable "access_allowed_emails" {
  description = "Specific email addresses permitted by Cloudflare Access. May be empty if access_allowed_email_domains is set."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.access_allowed_email_domains) + length(var.access_allowed_emails) >= 1
    error_message = "Provide at least one entry across access_allowed_email_domains and access_allowed_emails."
  }
}

variable "access_allowed_idp_ids" {
  description = "Cloudflare Access IdP IDs to restrict authentication to. If empty, all IdPs configured on the account are offered."
  type        = list(string)
  default     = []
}

variable "access_auto_redirect_to_identity" {
  description = "If true, skip the IdP picker and send users straight to the (single) configured IdP."
  type        = bool
  default     = false
}

variable "access_application_name" {
  description = "Display name for the Cloudflare Access application protecting Splunk Web. Defaults to <name_prefix>-splunk."
  type        = string
  default     = ""
}

variable "access_policy_name" {
  description = "Display name for the Cloudflare Access allow policy. Defaults to <name_prefix>-allow."
  type        = string
  default     = ""
}

variable "cloudflared_image" {
  description = "cloudflared Docker image (pinned). Runs as a sidecar container on the Splunk EC2 instance."
  type        = string
  default     = "cloudflare/cloudflared:2026.3.0"
}

# ─── Scheduler (business-hours start/stop) ──────────────────────────────

variable "scheduler_enabled" {
  description = "Master switch for the business-hours EventBridge scheduler. Set false to disable the start/stop schedules without removing the resources."
  type        = bool
  default     = true
}

variable "scheduler_timezone" {
  description = "IANA timezone for the EventBridge schedules."
  type        = string
  default     = "Australia/Sydney"
}

variable "scheduler_start_cron" {
  description = "cron(...) expression for the daily start schedule. Default: 09:00 Mon-Fri."
  type        = string
  default     = "cron(0 9 ? * MON-FRI *)"
}

variable "scheduler_stop_cron" {
  description = "cron(...) expression for the daily stop schedule. Default: 18:00 Mon-Fri."
  type        = string
  default     = "cron(0 18 ? * MON-FRI *)"
}

# ─── GitHub Actions OIDC ───────────────────────────────────────────────

variable "github_owner" {
  description = "GitHub organization or user that owns the repo (for OIDC trust)."
  type        = string
  default     = "TotallyWildAi"
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC trust)."
  type        = string
  default     = "splunk-detection-poc"
}

variable "create_github_oidc_provider" {
  description = "If true, create an IAM OIDC provider for token.actions.githubusercontent.com. The target account already has one from agent-observability, so the default is false; set true on a brand-new account."
  type        = bool
  default     = false
}

variable "github_oidc_provider_arn_existing" {
  description = "ARN of an existing GitHub OIDC provider in this account, used only when create_github_oidc_provider = false."
  type        = string
  default     = "arn:aws:iam::637675605233:oidc-provider/token.actions.githubusercontent.com"
}
