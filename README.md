# splunk-detection-poc

A self-contained Splunk detection-engineering POC demonstrating five capabilities end-to-end:

1. **Data parsing and ingestion** — CloudTrail, VPC Flow Logs, HEC, with `props.conf` / `transforms.conf` versioned in git
2. **Data Model Acceleration (DMA)** — CIM datamodels with acceleration, plus benchmarks and health monitoring
3. **Splunk detection engineering** — custom SPL detections mapped to MITRE ATT&CK, layered on top of [splunk/security_content](https://github.com/splunk/security_content)
4. **Detections as Code (CI/CD)** — GitHub Actions workflow: lint → validate → unit-test → deploy via Splunk REST API
5. **AI for detection development** — runbook + scripts showing threat-intel → Claude API → SPL draft → automated test

## Architecture

Splunk Enterprise (60-day trial) on a single EC2 instance in a private subnet of its own VPC. Browser access via a public Application Load Balancer terminating HTTPS with an AWS Certificate Manager cert; Cloudflare provides authoritative DNS only (DNS-only / grey-cloud CNAME to the ALB). Auth is Splunk's built-in admin login. CI/CD via GitHub Actions with OIDC-authenticated AWS access (no static keys).

Data flows in via an account-wide multi-region CloudTrail → S3 → SQS event notifications → `Splunk_TA_aws` "SQS-Based S3" modular input → indexed as `sourcetype=aws:cloudtrail` into `index=main`. CIM datamodel acceleration is enabled for `Change` and `Authentication` so detection content (`tstats`-based) runs in milliseconds.

```
splunk-detection-poc/
├── README.md
├── .gitignore
├── .gitattributes
├── .github/workflows/         GH Actions — terraform + detection deploy
├── terraform/                 IaC root + modules
│   ├── modules/
│   │   ├── vpc/               Dedicated VPC (10.2.0.0/16), 1 NAT GW, 2 public subnets (ALB), 1 private subnet
│   │   ├── splunk/            EC2 + cloud-init Splunk install + EBS
│   │   ├── alb/               Public ALB + ACM cert + Cloudflare DNS records
│   │   ├── cloudtrail_ingest/ CloudTrail trail + S3 bucket + SQS queue + S3->SQS notifications
│   │   └── scheduler/         EventBridge schedule to start/stop EC2 (business hrs)
│   └── envs/
├── apps-src/                  First-party Splunk apps (versioned in git)
│   └── tw_cim_accel/          CIM datamodel acceleration overrides + benchmark dashboard (named `tw_*` to win the Splunk_SA_CIM precedence battle)
├── splunk-apps/               Third-party Splunkbase packages (.tgz/.spl, gitignored)
├── scripts/sync-apps.sh       Builds .tgz from apps-src/, syncs all to S3, triggers install on EC2
├── detections/                Detection content (YAML + SPL), validated in CI
├── dashboards/                Splunk dashboards as code (XML / JSON)
├── docs/                      Demo walkthrough, runbooks
├── demo-data/                 Sample events for unit-testing detections
└── ai-workflow/               AI-assisted detection authoring scripts + prompts
```

## Status

Build in progress. See the Phase status section once Phase 1 lands.

## Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1   | Skeleton + Splunk EC2 + ALB + HTTPS + ACM (Splunk native auth) + GH Actions OIDC + business-hours scheduler | Done |
| 2.1 | CloudTrail → S3 → SQS → TA-aws ingestion | Done |
| 2.2 | VPC Flow Logs ingestion | Planned |
| 2.3 | GuardDuty findings ingestion | Planned |
| 2.4 | HEC examples (synthetic auth-fail events) | Planned |
| 3   | DMA: CIM datamodels (Change, Authentication) accelerated + benchmark dashboard | Done |
| 4   | 5-10 custom SPL detections + MITRE ATT&CK mapping | Planned |
| 5   | Detections-as-Code CI/CD (lint → validate → unit-test → deploy) | Planned |
| 6   | AI detection workflow (threat-intel → Claude → SPL draft → test) | Planned |
| 7   | Demo polish (dashboards, README walkthrough) | Planned |

## Operational notes

A few non-obvious gotchas surfaced during the build — captured here so they're not lost.

**Terraform requires `CLOUDFLARE_API_TOKEN`** in shell for every `plan`/`apply`, even when the change you're making has nothing to do with DNS. The `alb` module owns `cloudflare_dns_record` resources (app CNAME + ACM validation records), so the Cloudflare provider refreshes them on every run. Export the token from your environment (or source `.env`).

**TA-aws "Signature Validate All Events" must be UNCHECKED** when configuring the SQS-Based S3 input. Our S3 sends notifications directly to SQS (no SNS wrapping), so messages have no SNS signature. With validation on (the UI default), TA-aws silently drops every message. The input's stored attr is `sqs_sns_validation=0`. To toggle via REST:

```bash
curl -ks -u admin@totallywild.ai:$PW -X POST \
  https://localhost:8089/servicesNS/nobody/Splunk_TA_aws/data/inputs/aws_sqs_based_s3/cloudtrail-mgmt \
  -d 'sqs_sns_validation=0'
```

**TA-aws Configuration page crashes on first load** with `cannot unpack non-iterable NoneType object` because it ships without an initial `aws_account.conf`. Seed an empty `[default]` stanza in `/opt/splunk/etc/apps/Splunk_TA_aws/local/aws_account.conf` and restart Splunk.

**Splunk 10.2.x boot-start requires careful ownership.** The `.deb` chowns `/opt/splunk` to `splunk:splunk`; running `splunk start --run-as-root` may leave new files root-owned. The systemd unit runs as `User=splunk`, so any root-owned files break the next stop/start cycle. `user_data.sh.tftpl` handles this by chowning back to `splunk:splunk` before enabling boot-start, and `install-apps.sh` re-chowns after each app install and uses `systemctl restart Splunkd` (not `splunk restart --run-as-root`).

## Cost (per env, ap-southeast-2, business hours schedule)

| Item | Monthly |
|---|---|
| Splunk EC2 (m5.xlarge, ~50h/week) | ~$28 |
| EBS storage (200 GB gp3) | ~$16 |
| NAT Gateway (1, business hours stop optional) | ~$10–33 |
| EventBridge + Lambda (scheduler) | <$1 |
| ALB (always-on, low traffic) | ~$18 |
| ACM certificate (public, DNS-validated) | $0 |
| Cloudflare DNS (authoritative-only) | $0 |
| S3 + CloudWatch Logs + KMS | ~$2 |
| **Total** | **~$70–100/mo** |

24/7 mode adds ~$100/mo for full Splunk uptime.

## Splunk licensing

60-day Enterprise Trial → auto-converts to Free tier (500 MB/day ingest, no scheduled searches). Plenty for POC demo. For production-grade workload, swap to a paid license or Splunk Cloud.
