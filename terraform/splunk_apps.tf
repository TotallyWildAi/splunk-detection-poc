# Splunk app packages: the BUCKET is managed by Terraform, but the OBJECTS
# inside it are NOT — they're synced from the local `../splunk-apps/`
# directory by `scripts/sync-apps.sh` (run manually from a developer machine).
#
# Why this split?
# The app .tgz/.tar.gz/.spl files are too big to commit to git AND vendor-
# licensed (some Splunkbase ToS prohibit redistribution). They live locally
# at `../splunk-apps/`, gitignored. If we managed objects via
# `aws_s3_object` + `fileset()`, CI's checkout would find an empty
# `splunk-apps/` directory and Terraform would happily destroy every
# object in the bucket on the next CI apply. Removing object management
# from Terraform avoids that footgun entirely.
#
# Workflow:
#   1. Drop new .tgz / .tar.gz / .spl / .zip into ../splunk-apps/
#   2. ./scripts/sync-apps.sh         (uploads + triggers re-install on EC2)
#
# Versioning is on so we keep a history of app uploads (rollback path).

resource "aws_s3_bucket" "splunk_apps" {
  bucket = "${local.name_prefix}-apps-${local.account_id}"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-apps"
  })
}

resource "aws_s3_bucket_versioning" "splunk_apps" {
  bucket = aws_s3_bucket.splunk_apps.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "splunk_apps" {
  bucket = aws_s3_bucket.splunk_apps.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "splunk_apps" {
  bucket = aws_s3_bucket.splunk_apps.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
