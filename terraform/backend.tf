terraform {
  backend "s3" {
    # Backend configuration is supplied at init time via -backend-config so
    # the same Terraform root can target any AWS environment without code
    # changes. See envs/EXAMPLE.backend.hcl for the template.
    #
    #   terraform init -backend-config=../envs/<env>.backend.hcl
  }
}
