# Splunk app packages: local files under ../splunk-apps/ get uploaded to a
# private S3 bucket on `terraform apply`, then the Splunk EC2 pulls them down
# at boot via cloud-init and installs each one.
#
# Bucket layout:
#   s3://${local.name_prefix}-apps-${local.account_id}/<filename>
#
# Versioning is enabled so we keep a history of app uploads (rollback path).
# data.aws_caller_identity.current is already declared in locals.tf.

locals {
  splunk_apps_dir   = "${path.root}/../splunk-apps"
  splunk_apps_files = fileset(local.splunk_apps_dir, "*.{tgz,tar.gz,spl,zip}")
}

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

# Upload every local app package. etag = filemd5(...) so Terraform re-uploads
# when the local file content changes.
resource "aws_s3_object" "splunk_apps" {
  for_each = local.splunk_apps_files

  bucket = aws_s3_bucket.splunk_apps.id
  key    = each.value
  source = "${local.splunk_apps_dir}/${each.value}"
  etag   = filemd5("${local.splunk_apps_dir}/${each.value}")

  tags = local.common_tags
}
