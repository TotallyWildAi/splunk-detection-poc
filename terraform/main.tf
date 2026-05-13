provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Cloudflare API token is read from CLOUDFLARE_API_TOKEN env var. No provider
# config required here.
provider "cloudflare" {}

# ─── Modules ──────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zone    = var.availability_zone
  availability_zone_b  = var.availability_zone_b
  public_subnet_cidr   = var.public_subnet_cidr
  public_subnet_b_cidr = var.public_subnet_b_cidr
  private_subnet_cidr  = var.private_subnet_cidr

  tags = local.common_tags
}

module "splunk" {
  source = "./modules/splunk"

  name_prefix           = local.name_prefix
  aws_region            = var.aws_region
  vpc_id                = module.vpc.vpc_id
  private_subnet_id     = module.vpc.private_subnet_id
  instance_type         = var.splunk_instance_type
  root_volume_size_gb   = var.splunk_root_volume_size_gb
  splunk_admin_email    = var.splunk_admin_email
  splunk_deb_url        = var.splunk_deb_url
  splunk_version        = var.splunk_version
  instance_profile_name = aws_iam_instance_profile.splunk_ec2.name
  apps_s3_bucket        = aws_s3_bucket.splunk_apps.bucket

  tags = local.common_tags

  # The EC2 cloud-init script needs internet (apt update, splunk download).
  # Without this dependency Terraform can race ahead and create the EC2
  # before the NAT Gateway + private route table association are ready, and
  # cloud-init fails on apt-get with "Network is unreachable".
  depends_on = [module.vpc]
}

module "alb" {
  source = "./modules/alb"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = [module.vpc.public_subnet_id, module.vpc.public_subnet_id_b]
  vpc_cidr           = var.vpc_cidr
  splunk_instance_id = module.splunk.instance_id
  splunk_sg_id       = module.splunk.security_group_id
  hostname           = var.splunk_web_hostname
  cloudflare_zone_id = var.cloudflare_zone_id

  tags = local.common_tags
}

module "scheduler" {
  source = "./modules/scheduler"

  name_prefix  = local.name_prefix
  enabled      = var.scheduler_enabled
  instance_id  = module.splunk.instance_id
  instance_arn = module.splunk.instance_arn
  timezone     = var.scheduler_timezone
  start_cron   = var.scheduler_start_cron
  stop_cron    = var.scheduler_stop_cron

  tags = local.common_tags
}
