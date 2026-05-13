# Disaster recovery runbook

How to recover this POC after various failure modes. Verified end-to-end on
2026-05-13 by `terraform apply -replace`'ing the Splunk EC2 and re-running
the `splunk-config` workflow on a green-field instance — every piece of
state was reproduced from git in ~15 minutes total.

## Scope

| Failure mode | This runbook covers |
|---|---|
| Splunk EC2 corrupted / OS broken / disk full | ✅ Step 2 |
| Splunk EC2 terminated / EBS deleted | ✅ Step 2 |
| All Splunk content drifted / wrong / wiped | ✅ Step 3 alone |
| VPC / ALB / SQS / IAM destroyed | ✅ Steps 1 + 2 + 3 |
| AWS account deleted | ❌ — re-onboard from scratch (see README) |
| Cloudflare zone broken | ❌ — DNS-layer, fix in Cloudflare dashboard |

## What's preserved across a Splunk-EC2 rebuild

| State | Where | Survives? |
|---|---|---|
| AWS infra (VPC, NAT, ALB, IAM, S3, SQS, Secrets Manager) | Terraform-managed | ✅ |
| Splunk admin password | Secrets Manager | ✅ |
| Splunkbase app binaries | `s3://splunk-poc-apps-...` | ✅ |
| CloudTrail history (30d) | `s3://splunk-poc-cloudtrail-...` | ✅ |
| VPC Flow Logs history (30d) | `s3://splunk-poc-vpcflow-...` | ✅ |
| ALB target attachment | TF re-creates | ✅ |
| Cloudflare DNS record | TF-managed, unchanged | ✅ |
| Indexed events in Splunk | EBS (delete_on_termination=true) | ❌ — see "data recovery" below |
| Splunkd KV store (SSE custom_content) | EBS | ❌ — rebuilt by CI |
| Saved searches | EBS | ❌ — rebuilt by CI |
| TA-aws account + input stanzas | EBS | ❌ — rebuilt by CI |

## Pre-requisites for the runbook operator

- AWS CLI authenticated to the test account (`637675605233`) with permission to assume the `splunk-poc-gha-deploy` role OR a sufficiently-scoped human role
- Terraform 1.10+
- `gh` CLI authenticated to the `TotallyWildAi/splunk-detection-poc` repo
- `CLOUDFLARE_API_TOKEN` exported (read from `.env`)

---

## Step 1 — Rebuild AWS infrastructure (if destroyed)

Only needed if the VPC / ALB / SQS / IAM / S3 buckets have been destroyed.
For an EC2-only failure, skip to Step 2.

```bash
cd terraform
export CLOUDFLARE_API_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' /path/to/.env | cut -d= -f2-)"
terraform init -backend-config=../envs/test.backend.hcl
terraform plan  -var-file=../envs/test.tfvars -out=recover.tfplan
terraform apply recover.tfplan
```

Expected output: `Apply complete! Resources: N added, 0 changed, 0 destroyed.`
Time: ~5–15 min depending on what's being rebuilt.

If the S3 state bucket itself is gone, you'll need to bootstrap a new
state backend first — see README's "deploy to a new customer" notes.

---

## Step 2 — Replace the Splunk EC2

The most common DR scenario. Forces a fresh boot from `user_data.sh.tftpl`,
which:
- Installs Splunk Enterprise 10.2.3 from the pinned .deb URL
- Seeds the admin password from Secrets Manager
- Configures boot-start (systemd unit, `User=splunk`, idempotent across
  scheduler-driven stop/start cycles)
- Runs `install-apps.sh` once — pulls every package from
  `s3://splunk-poc-apps-...`, installs each one, then syncs
  `tw_cim_accel/default/datamodels.conf` into
  `Splunk_SA_CIM/local/datamodels.conf` (the only place Splunk reliably
  honors DMA acceleration overrides; see `README.md` operational notes)

```bash
cd terraform
export CLOUDFLARE_API_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' /path/to/.env | cut -d= -f2-)"
terraform apply -var-file=../envs/test.tfvars \
                -replace=module.splunk.aws_instance.splunk
```

This destroys the old EC2 (and its EBS volume) and creates a new one with
a new instance ID and IP. Terraform updates the ALB target attachment
automatically. Cloudflare CNAME is unchanged (points at the ALB DNS, not
the instance IP).

Wait ~6–8 min for cloud-init to complete. Monitor via SSM:

```bash
INSTANCE_ID=$(terraform output -raw splunk_instance_id)
aws ssm send-command --instance-ids "$INSTANCE_ID" --region ap-southeast-2 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -3 /var/log/splunk-bootstrap.log"]' \
  --query 'Command.CommandId' --output text
```

You're done with Step 2 when the bootstrap log shows `[bootstrap] done <ts>`.

Verify ALB target health:

```bash
TG_ARN=$(aws elbv2 describe-target-groups --names splunk-poc-splunk-web \
  --region ap-southeast-2 --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --region ap-southeast-2 --query 'TargetHealthDescriptions[0].TargetHealth.State'
# Expect: "healthy" (may take ~60s after splunkd is listening)
```

Hit `https://splunk-poc.totallywild.ai/` — should return HTTP 200 (Splunk
login page) within ~60s of `[bootstrap] done`.

---

## Step 3 — Redeploy Splunk content via CI

After an EC2 rebuild, the Splunk instance has apps installed (from
`install-apps.sh`) but **no live runtime content**: no SSE custom_content
rows, no TWAi saved searches, no TA-aws account/input stanzas. The
`splunk-config` workflow rebuilds all of this from git.

Trigger it manually:

```bash
gh workflow run splunk-config --repo TotallyWildAi/splunk-detection-poc --ref main
```

Then wait for it to finish:

```bash
gh run watch --repo TotallyWildAi/splunk-detection-poc
```

The workflow runs five jobs (all four deploy jobs gated to push/dispatch
on main):

| Job | What it does |
|---|---|
| `validate` | YAML schema check on `detections/*.yml`, .conf sanity on `apps-src/**/*.conf` |
| `deploy-apps` | Builds .tgz from `apps-src/`, syncs to S3, SSM-triggers `install-apps.sh` on EC2 |
| `deploy-sse-content` | Compiles `detections/*.yml` → ShowcaseInfo rows, PUTs to SSE `custom_content` KV store |
| `deploy-detections` | Compiles `detections/*.yml` → REST payloads, POSTs to `/services/saved/searches` |
| `deploy-taaws-config` | Compiles `taaws-config/config.yml` → REST payloads, POSTs to TA-aws account + input endpoints |

Expected runtime: 4–6 min.

---

## Step 4 — Verify

```bash
INSTANCE_ID=$(terraform -chdir=terraform output -raw splunk_instance_id)
PW=$(aws secretsmanager get-secret-value --region ap-southeast-2 \
       --secret-id splunk-poc/splunk-admin-password \
       --query SecretString --output text)

# Run via SSM (no public 8089 exposure):
aws ssm send-command --instance-ids "$INSTANCE_ID" --region ap-southeast-2 \
  --document-name AWS-RunShellScript --parameters "commands=[
    \"curl -ks -u 'admin@totallywild.ai:$PW' 'https://localhost:8089/servicesNS/nobody/tw_cim_accel/saved/searches?output_mode=json&count=0&search=TWAi' | python3 -c 'import sys,json; print(\\\"saved searches:\\\", len([e for e in json.load(sys.stdin)[\\\"entry\\\"] if e[\\\"name\\\"].startswith(\\\"TWAi\\\")]))'\",
    \"curl -ks -u 'admin@totallywild.ai:$PW' 'https://localhost:8089/servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/custom_content' | python3 -c 'import sys,json; print(\\\"SSE rows:\\\", len(json.load(sys.stdin)))'\",
    \"ls /opt/splunk/etc/apps/Splunk_SA_CIM/local/datamodels.conf\"
  ]"
```

The expected results:

| Check | Expected |
|---|---|
| TWAi saved searches | 7 |
| SSE custom_content rows | 7 |
| `Splunk_SA_CIM/local/datamodels.conf` | Present, with Change + Authentication + Network_Traffic stanzas |
| `index=main sourcetype=aws:cloudtrail` count (last 30 min) | > 0 — TA-aws is reading new events from SQS |
| `index=main sourcetype=aws:cloudwatchlogs:vpcflow` count (last 30 min) | > 0 |

Plus an end-user check: browse to
`https://splunk-poc.totallywild.ai/en-GB/app/Splunk_Security_Essentials/mitre_overview`
— the 7 TWAi detections appear in the MITRE ATT&CK heat map (filterable
by Originating App = `TotallyWildAi Detections`).

---

## Data recovery (historical events)

Splunk indexed events live on the EC2's EBS root volume, which has
`delete_on_termination = true` — destroyed with the instance. After a
rebuild, the indexer starts empty.

**Steady-state ingestion** resumes immediately (TA-aws is reading from
the SQS queues, which keep receiving new S3 event notifications as
CloudTrail and VPC Flow Logs deliver fresh records every 5–15 min).

**Historical events back to ~30 days** are still in S3, but SQS messages
have ~4-day retention and any message already consumed before the
rebuild is gone. To force-replay:

1. Read each S3 object key from `s3://splunk-poc-cloudtrail-.../AWSLogs/...`
   and `s3://splunk-poc-vpcflow-.../AWSLogs/...`
2. For each one, push an `s3:ObjectCreated:Put` notification message to
   the matching SQS queue (the queue ARNs are in the `cloudtrail_ingest`
   and `vpc_flow_logs_ingest` Terraform module outputs)
3. TA-aws will fetch each one and index it

A 5-line `boto3` script does this — not in this repo yet because the
POC doesn't need it. Add a `scripts/replay-from-s3.py` if a real recovery
needs it.

For most demo / POC purposes the steady-state re-ingestion is fine —
detections will start firing again within ~10 min of the rebuild.

---

## Common failure modes and how to fix

### `[bootstrap] done` never appears

Check `/var/log/splunk-bootstrap.log` via SSM. Common causes:
- **NAT Gateway not ready yet** when cloud-init started → apt-get fails.
  Solved by the `depends_on = [module.vpc]` chain in `terraform/main.tf`;
  if you've torn down and re-applied the VPC module without it, the race
  comes back.
- **Splunk .deb download failure** → check the EC2 has internet egress
  via the NAT Gateway; verify with `curl https://download.splunk.com` from SSM.
- **`splunk start` fails silently** → confirm `--run-as-root` is on every
  splunk command in `user_data.sh.tftpl` (10.2.x deprecated implicit-root
  execution).

### Workflow `deploy-taaws-config` fails with HTTP 400 "Cannot edit ... does not exist"

The TA-aws input REST handler returns 400 (not 404) when an input
doesn't exist. The on-host script handles this via a GET-first existence
check; if the failure recurs, the bug fix in commit `a08e289` may have
regressed. Re-check `scripts/on-host/sync-taaws-config.sh`.

### Detections / SSE rows present but no data flowing

`sqs_sns_validation=0` is the most common cause of silent ingestion
failure. Verify via REST:

```bash
curl -ks -u "admin@totallywild.ai:$PW" \
  'https://localhost:8089/servicesNS/-/Splunk_TA_aws/data/inputs/aws_sqs_based_s3?output_mode=json' \
  | python3 -c "import sys,json; [print(e['name'], e['content'].get('sqs_sns_validation')) for e in json.load(sys.stdin)['entry']]"
```

Both inputs must show `0`. If `1`, the TA-aws Configuration UI was used
instead of our REST-based deploy — `bash scripts/deploy-taaws-config.sh`
will reset it.

### DMA never builds (acceleration stuck off)

Check the effective config:

```bash
/opt/splunk/bin/splunk cmd btool datamodels list Change --debug \
  | grep 'acceleration ='
```

Should show `acceleration = true` from `Splunk_SA_CIM/local/datamodels.conf`.
If it shows `false` from `Splunk_SA_CIM/default/datamodels.conf`, our sync
step in `install-apps.sh` didn't run. Force it:

```bash
INSTANCE_ID=$(terraform -chdir=terraform output -raw splunk_instance_id)
aws ssm send-command --instance-ids "$INSTANCE_ID" --region ap-southeast-2 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["bash /opt/splunk-poc/install-apps.sh"]'
```

---

## Expected total downtime

| Operation | Time |
|---|---|
| `terraform apply -replace` (EC2 destroy + create) | ~3 min |
| cloud-init (Splunk install + apps install from S3) | ~6 min |
| ALB health-check stabilization | ~60s |
| `splunk-config` workflow (validate + 4 deploy jobs) | ~5 min |
| **Total: from `replace` invocation to first detections firing** | **~15 min** |

Steady-state ingestion of *new* events starts immediately once TA-aws
inputs are configured by the workflow (Step 3). Historical re-ingestion
from S3 needs the optional replay script (above).
