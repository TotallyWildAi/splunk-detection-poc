# Splunk Enterprise single-host EC2.
#
# - Ubuntu 22.04 LTS (Canonical owner ID 099720109477)
# - Private subnet, no public IP
# - SSM Session Manager only (no SSH key pair)
# - cloudflared runs as a Docker sidecar in user-data, fronts ports 8000+8088
# - Admin password materialized from Secrets Manager at first boot

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# ─── Security group ───────────────────────────────────────────────────
# All ingress from the public internet is blocked (no public IP anyway).
# cloudflared reaches Splunk over localhost on the same host, so we don't
# need any ingress rules. Egress is wide-open: package mirrors, Cloudflare
# edge, Splunk download, Secrets Manager API, SSM endpoints, etc.
resource "aws_security_group" "splunk" {
  name        = "${var.name_prefix}-splunk"
  description = "Splunk Enterprise EC2 (egress-only; cloudflared sidecar reaches Splunk on localhost)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name_prefix}-splunk" })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.splunk.id
  description       = "Allow all egress (Splunk download, package mirrors, Cloudflare edge, SSM endpoints)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ─── Cloud-init user-data ─────────────────────────────────────────────
locals {
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    splunk_admin_email        = var.splunk_admin_email
    splunk_deb_url            = var.splunk_deb_url
    admin_password_secret_arn = aws_secretsmanager_secret.admin.arn
    tunnel_token_secret_arn   = var.tunnel_token_secret_arn
    aws_region                = var.aws_region
    cloudflared_image         = var.cloudflared_image
  })
}

# ─── EC2 instance ─────────────────────────────────────────────────────
resource "aws_instance" "splunk" {
  ami           = data.aws_ami.ubuntu_2204.id
  instance_type = var.instance_type

  subnet_id                   = var.private_subnet_id
  vpc_security_group_ids      = [aws_security_group.splunk.id]
  associate_public_ip_address = false

  iam_instance_profile = var.instance_profile_name

  # Require IMDSv2.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(var.tags, { Name = "${var.name_prefix}-splunk-root" })
  }

  user_data                   = local.user_data
  user_data_replace_on_change = false

  tags = merge(var.tags, {
    Name          = "${var.name_prefix}-splunk"
    SplunkVersion = var.splunk_version
  })

  # Ensure the admin secret + tunnel token secret values are written before
  # the instance boots and cloud-init tries to read them.
  depends_on = [
    aws_secretsmanager_secret_version.admin,
  ]
}
