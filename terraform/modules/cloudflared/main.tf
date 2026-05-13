# Cloudflare Tunnel + Access app for the Splunk POC.
#
# This module owns the *control-plane* side of the tunnel: the tunnel
# resource, the ingress config (two hostnames -> two upstream ports on the
# Splunk EC2 instance), the DNS records, the Access app, and the Access
# policy. The tunnel token is stashed in AWS Secrets Manager.
#
# It does NOT own the cloudflared *daemon*. Unlike agent-observability —
# which runs cloudflared as an ECS Fargate task — this stack runs cloudflared
# as a Docker container sidecar on the Splunk EC2 host (no ECS cluster
# needed for a single sidecar). That daemon is provisioned by the splunk
# module via cloud-init, consuming this module's tunnel_token_secret_arn.

# ─── Cloudflare Tunnel ────────────────────────────────────────────────
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.cloudflare_account_id
  name       = "${var.name_prefix}-tunnel"
  config_src = "cloudflare"
}

# Ingress rules controlled remotely (config_src = "cloudflare"). Two
# hostnames: one for Splunk Web (UI, port 8000) and one for HEC
# (ingestion, port 8088).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = [
      {
        hostname = var.splunk_web_hostname
        service  = var.splunk_web_internal_url
        origin_request = {
          http_host_header = var.splunk_web_hostname
        }
      },
      {
        hostname = var.splunk_hec_hostname
        service  = var.splunk_hec_internal_url
        origin_request = {
          http_host_header = var.splunk_hec_hostname
        }
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

# Token used by the cloudflared daemon to authenticate to the tunnel.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# ─── Tunnel token storage in AWS Secrets Manager ──────────────────────
# Consumed at boot by the cloudflared Docker container on the Splunk EC2 host
# (the splunk module's instance profile is allowed to read this secret via
# its <name_prefix>/* + <name_prefix>-* policy).
resource "aws_secretsmanager_secret" "tunnel_token" {
  name        = "${var.name_prefix}-tunnel-token"
  description = "Cloudflare Tunnel token consumed by the cloudflared sidecar on the Splunk EC2."
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "tunnel_token" {
  secret_id     = aws_secretsmanager_secret.tunnel_token.id
  secret_string = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
}

# ─── DNS: hostname CNAME -> <tunnel-id>.cfargotunnel.com ──────────────
resource "cloudflare_dns_record" "splunk_web" {
  zone_id = var.cloudflare_zone_id
  name    = var.splunk_web_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "splunk_hec" {
  zone_id = var.cloudflare_zone_id
  name    = var.splunk_hec_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# ─── Cloudflare Access: single allow policy ──────────────────────────
locals {
  access_policy_name = var.access_policy_name != "" ? var.access_policy_name : "${var.name_prefix}-allow"
  access_app_name    = var.access_application_name != "" ? var.access_application_name : "${var.name_prefix}-splunk"

  access_include = concat(
    [for d in var.access_allowed_email_domains : { email_domain = { domain = d } }],
    [for e in var.access_allowed_emails : { email = { email = e } }],
  )
}

resource "cloudflare_zero_trust_access_policy" "this" {
  account_id = var.cloudflare_account_id
  name       = local.access_policy_name
  decision   = "allow"
  include    = local.access_include
}

# ─── Cloudflare Access: self-hosted application ──────────────────────
# Single app covering both hostnames. The Splunk Web side enforces SSO at the
# Cloudflare edge (Nick / Dimi only). HEC is the same app so it gets the same
# Access protection — for ingestion clients we'll later use a service token
# (Cf-Access-Client-Id / Cf-Access-Client-Secret) and add a service-auth
# policy. For Phase 1 we just establish the tunnel + the SSO-protected app.
resource "cloudflare_zero_trust_access_application" "splunk" {
  account_id                = var.cloudflare_account_id
  name                      = local.access_app_name
  type                      = "self_hosted"
  session_duration          = "24h"
  auto_redirect_to_identity = var.access_auto_redirect_to_identity
  app_launcher_visible      = false
  allowed_idps              = var.access_allowed_idp_ids

  destinations = [
    {
      type = "public"
      uri  = var.splunk_web_hostname
    },
    {
      type = "public"
      uri  = var.splunk_hec_hostname
    },
  ]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.this.id
      precedence = 1
    },
  ]
}
