# Copy this file to <env>.backend.hcl (gitignored) and fill in env-specific values.
#
# Init with:
#   cd terraform
#   terraform init -backend-config=../envs/<env>.backend.hcl
#
# Convention: reuse the env's existing TF state bucket, but pick a unique key
# so this stack's state doesn't collide with other Terraform projects in the
# same env.
#
# Locking: native S3 locking via `use_lockfile = true` (Terraform 1.10+).
# DynamoDB lock tables are deprecated and not used here.

bucket       = "your-tf-state-bucket-name"
key          = "splunk-detection-poc/test/terraform.tfstate"
region       = "ap-southeast-2"
use_lockfile = true
encrypt      = true
