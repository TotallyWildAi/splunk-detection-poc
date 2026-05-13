# Public ALB fronting Splunk Web on a private-subnet EC2.
#
# Traffic flow:
#   Browser (HTTPS) -> ALB (public subnets, :443, ACM cert)
#                       -> target group (HTTP :8000)
#                       -> Splunk EC2 (private subnet)
#
# DNS is on Cloudflare (the totallywild.ai zone). This module owns:
#   - one application CNAME (hostname -> alb_dns_name, DNS-only / grey cloud)
#   - the ACM DNS-validation CNAMEs (also DNS-only)
# Cloudflare is purely an authoritative DNS provider here — no proxy, no
# Tunnel, no Access app. Splunk's built-in admin login handles auth.

# ─── ALB security group ───────────────────────────────────────────────
# POC: 443 open to the world. For production, replace cidr_ipv4 = "0.0.0.0/0"
# with a CIDR/SG-source allowlist (e.g. office IPs, VPN egress, or a
# Cloudflare-edge IP set if you re-introduce proxying).
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public ALB fronting Splunk Web (443 to 8000)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the public internet (POC; restrict in production)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the public internet (redirected to HTTPS at the listener)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow ALB to reach the Splunk target on :8000 (and anything else)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ─── Splunk SG: accept :8000 from the ALB SG ──────────────────────────
# Declared as a standalone aws_vpc_security_group_ingress_rule (not inline
# on the Splunk SG) so the splunk module doesn't need to know about the
# ALB SG — avoids a circular module dependency.
resource "aws_vpc_security_group_ingress_rule" "splunk_from_alb" {
  security_group_id            = var.splunk_sg_id
  description                  = "Splunk Web from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.alb.id
}

# ─── ALB ──────────────────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

# ─── Target group: Splunk Web on :8000 ────────────────────────────────
# Health check hits Splunk's login page — returns 200 even before the user
# authenticates, so it's a reliable readiness probe. We accept 200-399 to be
# tolerant of any redirect Splunk may issue for the /en-US/ locale.
resource "aws_lb_target_group" "splunk_web" {
  name        = "${var.name_prefix}-splunk-web"
  port        = 8000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/en-US/account/login"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-splunk-web" })
}

resource "aws_lb_target_group_attachment" "splunk_web" {
  target_group_arn = aws_lb_target_group.splunk_web.arn
  target_id        = var.splunk_instance_id
  port             = 8000
}

# ─── ACM certificate (DNS validation via Cloudflare) ──────────────────
resource "aws_acm_certificate" "this" {
  domain_name       = var.hostname
  validation_method = "DNS"

  tags = merge(var.tags, { Name = var.hostname })

  lifecycle {
    create_before_destroy = true
  }
}

# Each domain_validation_options entry tells us which CNAME to publish in
# Cloudflare DNS. for_each by name so plans are stable.
resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = trimsuffix(each.value.value, ".")
  proxied = false
  ttl     = 1
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn = aws_acm_certificate.this.arn
  validation_record_fqdns = [
    for r in cloudflare_dns_record.acm_validation : r.name
  ]
}

# ─── Listeners ────────────────────────────────────────────────────────
# 443 -> target group. TLS13-1-2-2021-06 is the current AWS-recommended
# policy (TLS 1.3 with TLS 1.2 fallback).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.splunk_web.arn
  }

  tags = var.tags
}

# 80 -> redirect to 443 (cosmetic but standard).
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

# ─── Application DNS: hostname -> ALB ─────────────────────────────────
# DNS-only (grey cloud). Proxying would terminate TLS at the Cloudflare edge
# with a Cloudflare-issued cert, which is fine in theory but means the
# browser-visible cert is Cloudflare's, not ours. Keep DNS-only so the cert
# the browser sees is the ACM cert this module manages.
resource "cloudflare_dns_record" "app" {
  zone_id = var.cloudflare_zone_id
  name    = var.hostname
  type    = "CNAME"
  content = aws_lb.this.dns_name
  proxied = false
  ttl     = 1
}
