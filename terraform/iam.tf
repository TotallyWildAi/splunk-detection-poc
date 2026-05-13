# Splunk EC2 IAM instance profile. The instance needs:
#   - AmazonSSMManagedInstanceCore         (Session Manager shell access)
#   - secretsmanager:GetSecretValue        (admin password + tunnel token, scoped to this stack's secrets)

data "aws_iam_policy_document" "splunk_ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "splunk_ec2" {
  name               = "${local.name_prefix}-ec2"
  assume_role_policy = data.aws_iam_policy_document.splunk_ec2_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "splunk_ec2_ssm" {
  role       = aws_iam_role.splunk_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "splunk_ec2_secrets" {
  statement {
    sid     = "ReadStackSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}/*",
      "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${local.name_prefix}-*",
    ]
  }
}

resource "aws_iam_role_policy" "splunk_ec2_secrets" {
  name   = "${local.name_prefix}-ec2-secrets"
  role   = aws_iam_role.splunk_ec2.id
  policy = data.aws_iam_policy_document.splunk_ec2_secrets.json
}

resource "aws_iam_instance_profile" "splunk_ec2" {
  name = "${local.name_prefix}-ec2"
  role = aws_iam_role.splunk_ec2.name
  tags = local.common_tags
}
