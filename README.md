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
├── .gitignore                    Excludes splunk-apps/*.tgz, terraform/.terraform/, *.tfstate, envs/*.tfvars
├── .gitattributes                Enforces LF line endings for cross-platform deploys
├── .github/workflows/
│   ├── terraform.yml             plan/apply infra on PR/push when terraform/** changes
│   └── splunk-config.yml         validate + deploy apps + push SSE custom content on push when apps-src/** or detections/** changes
├── terraform/                    IaC root + modules
│   ├── main.tf                   wires the modules
│   ├── iam.tf                    Splunk EC2 instance role + profile, base SSM + Secrets Manager perms
│   ├── iam_github_oidc.tf        GitHub Actions OIDC trust + deploy role
│   ├── splunk_apps.tf            S3 bucket holding Splunk app packages (objects synced manually, not by TF)
│   ├── outputs.tf
│   ├── variables.tf
│   └── modules/
│       ├── vpc/                  Dedicated VPC (10.2.0.0/16), 1 NAT GW, 2 public subnets (ALB), 1 private subnet
│       ├── splunk/               EC2 + cloud-init Splunk install + EBS + admin Secrets Manager secret
│       ├── alb/                  Public ALB + ACM cert + Cloudflare DNS records
│       ├── cloudtrail_ingest/    CloudTrail trail + S3 bucket + SQS queue + S3->SQS notifications + Splunk role perms
│       ├── vpc_flow_logs_ingest/ Flow log + S3 bucket + SQS queue + Splunk role perms (Splunk-side input config pending)
│       └── scheduler/            EventBridge schedule to start/stop EC2 (business hrs)
├── envs/                         Per-env .tfvars + .backend.hcl (gitignored, EXAMPLE.* committed)
├── apps-src/                     First-party Splunk apps (versioned in git as unpacked dirs)
│   └── tw_cim_accel/             CIM acceleration override (Change + Authentication) + CloudTrail Authentication
│                                 mapping (eventtypes/tags/props) + DMA benchmark dashboard.
│                                 Named `tw_*` so it sorts AFTER `Splunk_SA_CIM` in app-precedence merge.
├── splunk-apps/                  Third-party Splunkbase packages (.tgz/.spl) - gitignored, README.md tracks what should live here
├── scripts/
│   ├── sync-apps.sh              Builds .tgz from apps-src/, syncs to S3, SSM-triggers install on EC2.
│   │                             Supports --custom-only and --no-delete flags for CI safety.
│   ├── compile-detections-to-sse.py
│   │                             Reads detections/**/*.yml, emits ShowcaseInfo rows ready for SSE custom_content KV-store.
│   ├── deploy-sse-custom-content.sh
│   │                             Runs the compiler, uploads JSON + on-host script to S3, SSM-triggers the writer on the EC2.
│   └── on-host/
│       └── sync-sse-content.sh   Runs ON the Splunk EC2: PUTs/POSTs each ShowcaseInfo row to /servicesNS/.../storage/collections/data/custom_content
├── detections/                   Detection content (YAML), schema-validated in CI
│   ├── SCHEMA.md                 YAML format spec - fields, MITRE mapping, tests block
│   └── aws/                      One file per detection, kebab-case
└── docs/
    └── splunk-enterprise-security-notes.md
                                  ES capabilities / what this POC has vs lacks + Mermaid architecture diagram
```

## Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1   | Skeleton + Splunk EC2 + ALB + HTTPS + ACM (Splunk native auth) + GH Actions OIDC + business-hours scheduler | Done |
| 2.1 | CloudTrail → S3 → SQS → TA-aws ingestion | Done |
| 2.2 | VPC Flow Logs ingestion (infra deployed; Splunk-side input config pending UI step) | Mostly done |
| 2.3 | GuardDuty findings ingestion | Planned |
| 2.4 | HEC examples (synthetic auth-fail events) | Planned |
| 3   | DMA: CIM datamodels (Change, Authentication) accelerated + benchmark dashboard | In progress (acceleration override pending) |
| 3.1 | CloudTrail → Authentication CIM mapping (eventtypes/tags/props in `tw_cim_accel`) | Done (181 events tagged as `authentication`) |
| 4   | 7 initial SPL detections + MITRE ATT&CK mapping in `detections/aws/` | Done |
| 4.5 | SSE Custom Content registration — detections appear in SSE MITRE ATT&CK heat map | Done (via `splunk-config` CI job `deploy-sse-content`) |
| 5   | Detections-as-Code REST deploy — compile `detections/*.yml` → `savedsearches.conf` via Splunk REST API | Planned |
| 6   | AI detection workflow (threat-intel → Claude → SPL draft → automated test) | Planned |
| 7   | Demo polish + runbook | Planned |

## CI/CD

Two-pipeline split so content changes don't run terraform plan/apply, and infra changes don't try to redeploy Splunk content.

**`.github/workflows/terraform.yml`** — triggers on `terraform/**` or `envs/EXAMPLE.*`. plan on PR (artifact), apply on push to main.

**`.github/workflows/splunk-config.yml`** — triggers on `apps-src/**`, `detections/**`, or `scripts/sync-apps.sh`. Jobs:
- `validate` — YAML schema check on `detections/*.yml`, .conf sanity on `apps-src/**/*.conf` (BOM, CRLF, duplicate stanzas).
- `deploy-apps` (push to main only) — `terraform init` (read-only, to fetch bucket + instance ID), `sync-apps.sh --custom-only --no-delete`, SSM-triggers `/opt/splunk-poc/install-apps.sh` on the EC2.
- `deploy-sse-content` (push to main only, needs `deploy-apps`) — compiles `detections/*.yml` to SSE ShowcaseInfo rows, uploads JSON + on-host script to S3, SSM-triggers the writer to PUT/POST rows into the SSE `custom_content` KV collection. After this runs, the detections show up in the SSE MITRE ATT&CK heat map filterable by Originating App = `TotallyWildAi Detections`.

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

**App precedence is case-insensitive alphabetical, later wins.** This bites any first-party app that tries to override `Splunk_SA_CIM`'s default `acceleration = false`. An app named `splunk_poc_cim_accel` sorts BEFORE `splunk_sa_cim` (poc < sa), so SA_CIM's `false` wins the merge and DMA never builds summaries. `splunk btool datamodels list Change --debug` reveals the merged source-of-each-key — use it to confirm overrides actually win. The fix is to rename the overriding app so it sorts after the base app (we use `tw_cim_accel`).

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
