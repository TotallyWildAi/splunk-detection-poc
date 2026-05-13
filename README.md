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
│   └── splunk-config.yml         validate + deploy apps/detections/SSE/TA-aws/data-inventory on push to apps-src/** | detections/** | taaws-config/** | sse-config/** | scripts/**
├── terraform/                    IaC root + modules
│   ├── main.tf                   wires the modules
│   ├── iam.tf                    Splunk EC2 instance role + profile, base SSM + Secrets Manager perms
│   ├── iam_github_oidc.tf        GitHub Actions OIDC trust + deploy role
│   ├── splunk_apps.tf            S3 bucket holding Splunk app packages (objects synced via sync-apps.sh, not TF)
│   ├── outputs.tf
│   ├── variables.tf
│   └── modules/
│       ├── vpc/                  Dedicated VPC (10.2.0.0/16), 1 NAT GW, 2 public subnets (ALB), 1 private subnet
│       ├── splunk/               EC2 + cloud-init Splunk install + EBS + admin Secrets Manager secret
│       ├── alb/                  Public ALB + ACM cert + Cloudflare DNS records
│       ├── cloudtrail_ingest/    CloudTrail trail + S3 bucket + SQS queue + S3->SQS notifications + Splunk role perms
│       ├── vpc_flow_logs_ingest/ Flow log + S3 bucket + SQS queue + Splunk role perms
│       └── scheduler/            EventBridge schedule to start/stop EC2 (business hrs)
├── envs/                         Per-env .tfvars + .backend.hcl (gitignored, EXAMPLE.* committed)
├── apps-src/                     First-party Splunk apps (versioned in git as unpacked dirs)
│   └── tw_cim_accel/             CIM acceleration override (Change + Authentication + Network_Traffic) +
│                                 CloudTrail Authentication mapping (eventtypes/tags/props) + DMA benchmark dashboard.
│                                 Named `tw_*` to satisfy app-precedence ordering; install-apps.sh syncs
│                                 datamodels.conf into Splunk_SA_CIM/local/ (the only path Splunk reliably
│                                 honors for datamodel-acceleration overrides).
├── splunk-apps/                  Third-party Splunkbase packages (.tgz/.spl) - gitignored, README.md tracks expected contents
├── taaws-config/                 Declarative TA-aws config-as-code (account + SQS-Based S3 input stanzas)
│   └── config.yml
├── sse-config/                   Declarative SSE state-as-code (Data Inventory product status)
│   └── data-inventory.yml
├── scripts/
│   ├── sync-apps.sh              Builds .tgz from apps-src/, syncs to S3, SSM-triggers install on EC2.
│   │                             Supports --custom-only and --no-delete flags for CI safety.
│   ├── compile-detections-to-sse.py            YAML -> SSE ShowcaseInfo rows
│   ├── compile-detections-to-savedsearches.py  YAML -> Splunk saved-search REST payloads
│   ├── compile-taaws-config.py                 YAML -> TA-aws account+input REST payloads
│   ├── compile-sse-data-inventory.py           YAML -> SSE data_inventory_products patches
│   ├── deploy-sse-custom-content.sh            local + CI driver, SSM-via-S3 -> custom_content KV-store
│   ├── deploy-detections.sh                    local + CI driver -> /services/saved/searches
│   ├── deploy-taaws-config.sh                  local + CI driver -> /servicesNS/.../Splunk_TA_aws
│   ├── deploy-sse-data-inventory.sh            local + CI driver -> data_inventory_products KV-store
│   └── on-host/                                executed on the EC2 via SSM (no public 8089 exposure)
│       ├── sync-sse-content.sh                 writes to SSE custom_content KV-store
│       ├── sync-detection-searches.sh          writes saved searches via REST
│       ├── sync-taaws-config.sh                writes TA-aws account + inputs via REST
│       └── sync-sse-data-inventory.sh          patches data_inventory_products KV-store
├── detections/                   Detection content (YAML), schema-validated in CI
│   ├── SCHEMA.md                 YAML format spec — fields, MITRE mapping, tests block
│   └── aws/                      One file per detection, kebab-case
└── docs/
    ├── splunk-enterprise-security-notes.md
    │                             ES capabilities / what this POC has vs lacks + Mermaid architecture diagram
    └── disaster-recovery.md      DR runbook — terraform apply -replace + workflow re-run, verified 2026-05-13
```

## Phases

| Phase | Description | Status |
|-------|-------------|--------|
| 1   | Skeleton + Splunk EC2 + ALB + HTTPS + ACM (Splunk native auth) + GH Actions OIDC + business-hours scheduler | **Done** |
| 2.1 | CloudTrail → S3 → SQS → TA-aws ingestion | **Done** |
| 2.2 | VPC Flow Logs ingestion (infra + TA-aws input stanza both in code) | **Done** |
| 2.3 | GuardDuty findings ingestion | Planned |
| 2.4 | HEC examples (synthetic auth-fail events) | Planned |
| 3   | DMA: Change + Authentication accelerated + benchmark dashboard | **Done** |
| 3.1 | CloudTrail → Authentication CIM mapping (eventtypes/tags/props in `tw_cim_accel`) | **Done** (180+ events tagged `authentication`) |
| 3.2 | Network_Traffic CIM datamodel accelerated for VPC Flow Logs | **Done** |
| 4   | 7 initial SPL detections + MITRE ATT&CK mapping in `detections/aws/` | **Done** |
| 4.5 | SSE Custom Content registration — detections appear in SSE MITRE ATT&CK heat map | **Done** (CI job `deploy-sse-content`) |
| 4.6 | SSE Data Inventory state-as-code (CIM Compliance dashboard + heat-map "Available" coloring unlock) | **Done** (CI job `deploy-sse-data-inventory`) |
| 5   | Detections-as-Code REST deploy — compile `detections/*.yml` → `/services/saved/searches` | **Done** (CI job `deploy-detections`; 7 scheduled saved searches live) |
| 5.1 | TA-aws account + SQS-Based S3 input stanzas as code | **Done** (CI job `deploy-taaws-config`) |
| DR  | Disaster-recovery runbook + EC2-rebuild test (terraform apply -replace + workflow_dispatch) | **Done** — see `docs/disaster-recovery.md`, verified 2026-05-13 |
| 6   | AI detection workflow (threat-intel → Claude → SPL draft → automated test) | Planned |
| 7   | Demo polish: walkthrough doc + screenshots + curated launcher dashboard | Planned (DR runbook done as a subset) |

## CI/CD

Two-pipeline split so content changes don't run terraform plan/apply, and infra changes don't try to redeploy Splunk content. Both workflows accept `workflow_dispatch` for manual re-runs.

**`.github/workflows/terraform.yml`** — triggers on `terraform/**` or `envs/EXAMPLE.*`. plan on PR (artifact), apply on push to main.

**`.github/workflows/splunk-config.yml`** — triggers on `apps-src/**`, `detections/**`, `taaws-config/**`, `sse-config/**`, or `scripts/**`. Jobs (in order):

1. **`validate`** — YAML schema check on `detections/*.yml`; .conf sanity check on `apps-src/**/*.conf` (UTF-8 BOM, CRLF endings, duplicate stanzas).
2. **`deploy-apps`** (push to main only) — `terraform init` (read-only, to fetch bucket + instance ID outputs), `sync-apps.sh --custom-only --no-delete`, SSM-triggers `/opt/splunk-poc/install-apps.sh` on the EC2.
3. **`deploy-sse-content`** (needs `deploy-apps`) — compiles `detections/*.yml` to SSE ShowcaseInfo rows, REST PUT/POST to SSE `custom_content` KV-store. After this runs, detections appear in the SSE MITRE ATT&CK heat map filterable by Originating App = `TotallyWildAi Detections`.
4. **`deploy-detections`** (needs `deploy-apps`) — compiles `detections/*.yml` to Splunk saved-search REST payloads, POSTs to `/services/saved/searches`. Creates / updates 7 scheduled, alerting saved searches.
5. **`deploy-taaws-config`** (needs `deploy-apps`) — compiles `taaws-config/config.yml` to TA-aws REST payloads, POSTs to `/servicesNS/.../Splunk_TA_aws/{splunk_ta_aws_aws_account,data/inputs/aws_sqs_based_s3}`. Creates / updates the AWS account stanza + the SQS-Based S3 input stanzas (CloudTrail + VPC Flow).
6. **`deploy-sse-data-inventory`** (needs `deploy-apps`) — compiles `sse-config/data-inventory.yml` to patch rows for SSE's `data_inventory_products` KV-store, REST POST. Marks our two AWS products as `status=success` so the CIM Compliance dashboard + MITRE heat-map "Available" coloring activate.

All four deploy jobs use the same SSM-via-S3 architecture: CI uploads payload + on-host script to S3, sends one SSM SendCommand, the EC2 fetches both from S3 and executes locally. The Splunk management port `:8089` is never exposed beyond the EC2's loopback.

## Disaster recovery

Full rebuild path documented in [`docs/disaster-recovery.md`](docs/disaster-recovery.md). Verified end-to-end on 2026-05-13:

1. `terraform apply -replace=module.splunk.aws_instance.splunk` — destroys + recreates the EC2 from `user_data.sh.tftpl`. ~6 min for cloud-init to finish.
2. `gh workflow run splunk-config` — re-deploys all Splunk content. ~5 min.
3. Total downtime from failure detection to first detection-eligible event indexed: **~15 minutes**.

Every piece of runtime state is reproducible from git. No hand-patches; the rebuild test specifically surfaced (and fixed) one bug — HTTP 400 vs 404 inconsistency in the TA-aws input REST handler — which would have bitten any future DR scenario.

## Operational notes

A few non-obvious gotchas surfaced during the build — captured here so they're not lost.

**Terraform requires `CLOUDFLARE_API_TOKEN`** in shell for every `plan`/`apply`, even when the change you're making has nothing to do with DNS. The `alb` module owns `cloudflare_dns_record` resources (app CNAME + ACM validation records), so the Cloudflare provider refreshes them on every run. Export the token from your environment (or source `.env`).

**TA-aws "Signature Validate All Events" must be UNCHECKED** when configuring the SQS-Based S3 input. Our S3 sends notifications directly to SQS (no SNS wrapping), so messages have no SNS signature. With validation on (the UI default), TA-aws silently drops every message. The input's stored attr is `sqs_sns_validation=0`. To toggle via REST:

```bash
curl -ks -u admin@totallywild.ai:$PW -X POST \
  https://localhost:8089/servicesNS/nobody/Splunk_TA_aws/data/inputs/aws_sqs_based_s3/cloudtrail-mgmt \
  -d 'sqs_sns_validation=0'
```

**TA-aws Configuration page crashes on first load** with `cannot unpack non-iterable NoneType object` because it ships without an initial `aws_account.conf`. Phase 5.1's REST-based account creation bypasses the UI entirely — the `deploy-taaws-config` CI job writes the account stanza directly, so this crash is no longer reachable in our flow.

**TA-aws input REST returns 400 (not 404) for non-existent entities.** When POSTing to `/data/inputs/aws_sqs_based_s3/<name>` for an input that doesn't exist, the handler returns `400 "Cannot edit ... because it does not exist"` rather than `404`. This breaks try-update-then-create-on-404 patterns. `scripts/on-host/sync-taaws-config.sh` works around this with a GET-first existence probe (GET correctly returns 404). Surfaced by the disaster-recovery rebuild test, fix is in `a08e289`.

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
