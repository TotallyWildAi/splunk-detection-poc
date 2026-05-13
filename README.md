# splunk-detection-poc

A self-contained Splunk detection-engineering POC demonstrating five capabilities end-to-end:

1. **Data parsing and ingestion** — CloudTrail, VPC Flow Logs, HEC, with `props.conf` / `transforms.conf` versioned in git
2. **Data Model Acceleration (DMA)** — CIM datamodels with acceleration, plus benchmarks and health monitoring
3. **Splunk detection engineering** — custom SPL detections mapped to MITRE ATT&CK, layered on top of [splunk/security_content](https://github.com/splunk/security_content)
4. **Detections as Code (CI/CD)** — GitHub Actions workflow: lint → validate → unit-test → deploy via Splunk REST API
5. **AI for detection development** — runbook + scripts showing threat-intel → Claude API → SPL draft → automated test

## Architecture

Splunk Enterprise (60-day trial) on a single EC2 instance in a private subnet of its own VPC. Browser access via a public Application Load Balancer terminating HTTPS with an AWS Certificate Manager cert; Cloudflare provides authoritative DNS only (DNS-only / grey-cloud CNAME to the ALB). Auth is Splunk's built-in admin login. CI/CD via GitHub Actions with OIDC-authenticated AWS access (no static keys).

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
│   │   ├── alb/                Public ALB + ACM cert + Cloudflare DNS records
│   │   └── scheduler/         EventBridge schedule to start/stop EC2 (business hrs)
│   └── envs/
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
| 1 | Skeleton + Splunk EC2 + ALB + HTTPS + ACM (Splunk native auth) + GH Actions OIDC + business-hours scheduler | Planned |
| 2 | Data ingestion (CloudTrail, VPC Flow Logs, HEC examples) | Planned |
| 3 | DMA: CIM datamodels with acceleration + benchmark dashboard | Planned |
| 4 | 5-10 custom SPL detections + MITRE ATT&CK mapping | Planned |
| 5 | Detections-as-Code CI/CD (lint → validate → unit-test → deploy) | Planned |
| 6 | AI detection workflow (threat-intel → Claude → SPL draft → test) | Planned |
| 7 | Demo polish (dashboards, README walkthrough) | Planned |

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
