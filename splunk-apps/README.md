# splunk-apps/

Splunk app packages (`.tgz`, `.spl`) for installation onto the Splunk POC
instance. The contents of this directory are uploaded to S3 by Terraform on
`apply`, and the Splunk EC2 instance downloads + installs them at boot via
cloud-init (or via `aws s3 sync` on demand).

The packages themselves are **gitignored** — they're third-party binaries
licensed under each vendor's terms, and at ~50-100 MB each they don't belong
in git history. The list of expected packages is enumerated below; copy them
into this directory from your local downloads.

## Currently shipped

| Package | Source | Purpose |
|---|---|---|
| `splunk-common-information-model-cim_850.tgz` | [Splunkbase #1621](https://splunkbase.splunk.com/app/1621) | CIM data models (Authentication, Network_Traffic, Endpoint, etc.) — foundation for DMA |
| `splunk-add-on-for-amazon-web-services-aws_811.spl` | [Splunkbase #1876](https://splunkbase.splunk.com/app/1876) | CloudTrail, VPC Flow Logs, GuardDuty, S3, CloudWatch ingestion |
| `splunk-security-essentials_383.tgz` | [Splunkbase #3435](https://splunkbase.splunk.com/app/3435) | UI for browsing detection content, MITRE ATT&CK coverage maps |
| `splunk-add-on-builder_451.tgz` | [Splunkbase #2962](https://splunkbase.splunk.com/app/2962) | UI tool for authoring custom ingestion add-ons |
| `splunk-es-content-update_5270.tar.gz` | [Splunkbase #3449](https://splunkbase.splunk.com/app/3449) | ~1000 pre-built detections from Splunk's security team, mapped to MITRE ATT&CK. Base library for Phase 4 custom detections. |

## Deployment flow

```
local clone  →  splunk-apps/ (gitignored, you populate manually)
                    │
                    ▼
            terraform apply  →  aws_s3_object for each file
                    │              uploads to s3://splunk-poc-apps-<acct>/<filename>
                    ▼
            cloud-init at EC2 boot:
              for each app in s3 bucket:
                aws s3 cp s3://splunk-poc-apps-<acct>/<file> /tmp/
                /opt/splunk/bin/splunk install app /tmp/<file> -auth admin:$PW
              /opt/splunk/bin/splunk restart
```

For app updates on a running instance, run:
```bash
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters 'commands=["/opt/splunk-poc/install-apps.sh"]'
```
(That script lives at `/opt/splunk-poc/install-apps.sh` on the EC2 instance, written by cloud-init.)
