data "aws_caller_identity" "current" {}

locals {
  name_prefix = var.name_prefix
  account_id  = data.aws_caller_identity.current.account_id

  common_tags = merge(
    {
      Project   = "splunk-detection-poc"
      ManagedBy = "terraform"
      Owner     = "platform"
    },
    var.environment_name != "" ? { Environment = var.environment_name } : {},
    var.common_tags,
  )
}
