variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "tags" {
  description = "Tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the tunnel and Access app."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the DNS records (CNAME -> tunnel)."
  type        = string
}

variable "splunk_web_hostname" {
  description = "Full FQDN that fronts Splunk Web on port 8000 (e.g. splunk-poc.totallywild.ai)."
  type        = string
}

variable "splunk_hec_hostname" {
  description = "Full FQDN that fronts Splunk HEC on port 8088 (e.g. splunk-poc-hec.totallywild.ai)."
  type        = string
}

variable "splunk_web_internal_url" {
  description = "Internal URL the tunnel forwards Splunk Web requests to (e.g. http://10.2.1.42:8000)."
  type        = string
}

variable "splunk_hec_internal_url" {
  description = "Internal URL the tunnel forwards HEC requests to (e.g. http://10.2.1.42:8088)."
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
}

variable "access_allowed_idp_ids" {
  description = "Cloudflare Access IdP IDs to restrict authentication to. If empty, all IdPs configured on the account are offered."
  type        = list(string)
  default     = []
}

variable "access_auto_redirect_to_identity" {
  description = "If true, skip the IdP picker and send users straight to the IdP. Only valid when exactly one IdP is allowed."
  type        = bool
  default     = false
}

variable "access_application_name" {
  description = "Display name for the Cloudflare Access application. Defaults to <name_prefix>-splunk."
  type        = string
  default     = ""
}

variable "access_policy_name" {
  description = "Display name for the Cloudflare Access allow policy. Defaults to <name_prefix>-allow."
  type        = string
  default     = ""
}
