#!/usr/bin/env bash
# Compile detections/*.yml -> SSE Custom Content rows, upload to the apps
# S3 bucket alongside the on-host sync script, then SSM-trigger the on-host
# script to write rows into the Splunk Security Essentials KV store.
#
# The management port :8089 is private (no ALB exposure). We deliberately
# don't expose it; CI shuttles the payload through S3 and the writes happen
# on the EC2 where localhost:8089 is reachable and the admin password is
# already in Secrets Manager.

set -euo pipefail

cd "$(dirname "$0")/.."

REGION=${AWS_REGION:-ap-southeast-2}
TF_DIR="terraform"
CONTENT_KEY="sse-content/custom_content.json"
SCRIPT_KEY="sse-content/sync-sse-content.sh"

if ! command -v terraform >/dev/null 2>&1; then echo "terraform not in PATH" >&2; exit 1; fi
if ! command -v aws >/dev/null 2>&1; then echo "aws not in PATH" >&2; exit 1; fi
if ! command -v python3 >/dev/null 2>&1; then echo "python3 not in PATH" >&2; exit 1; fi

BUCKET=$(terraform -chdir="$TF_DIR" output -raw splunk_apps_bucket)
INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw splunk_instance_id)
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_password_secret_arn)
ADMIN_USER=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_email)

echo "[deploy-sse] bucket: $BUCKET"
echo "[deploy-sse] instance: $INSTANCE_ID"
echo

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[deploy-sse] compiling detections/*.yml -> ShowcaseInfo rows"
python3 scripts/compile-detections-to-sse.py > "$STAGE/custom_content.json"
# Count rows via grep so the call is path-platform-agnostic (Git Bash on
# Windows hands python3 unix-style paths that Windows-native python can't
# resolve).
NUM_ROWS=$(grep -c '"_key"' "$STAGE/custom_content.json")
echo "[deploy-sse] compiled $NUM_ROWS rows"

echo
echo "[deploy-sse] uploading payload + on-host script to s3://$BUCKET/sse-content/"
aws s3 cp "$STAGE/custom_content.json"        "s3://$BUCKET/$CONTENT_KEY" --region "$REGION"
aws s3 cp scripts/on-host/sync-sse-content.sh "s3://$BUCKET/$SCRIPT_KEY"  --region "$REGION"

# Build the SSM SendCommand payload. The on-host commands are a single
# array element so the script body and the bash invocation stay in one
# logical step.
PAYLOAD_FILE=$(mktemp); trap 'rm -rf "$STAGE" "$PAYLOAD_FILE"' EXIT
python3 - "$BUCKET" "$CONTENT_KEY" "$SCRIPT_KEY" "$SECRET_ARN" "$ADMIN_USER" "$REGION" "$INSTANCE_ID" > "$PAYLOAD_FILE" <<'PYEND'
import json, sys
bucket, content_key, script_key, secret_arn, admin_user, region, instance_id = sys.argv[1:8]
cmd = (
    f"aws s3 cp --region '{region}' 's3://{bucket}/{script_key}' /tmp/sync-sse-content.sh && "
    f"chmod +x /tmp/sync-sse-content.sh && "
    f"/tmp/sync-sse-content.sh '{bucket}' '{content_key}' '{secret_arn}' '{admin_user}' '{region}'"
)
print(json.dumps({
    "DocumentName": "AWS-RunShellScript",
    "InstanceIds": [instance_id],
    "Parameters": {"commands": [cmd]},
}))
PYEND

if command -v cygpath >/dev/null 2>&1; then
  PAYLOAD_URI="file://$(cygpath -w "$PAYLOAD_FILE")"
else
  PAYLOAD_URI="file://$PAYLOAD_FILE"
fi

echo
echo "[deploy-sse] sending SSM command"
CMD_ID=$(aws ssm send-command --cli-input-json "$PAYLOAD_URI" --region "$REGION" --query 'Command.CommandId' --output text)
echo "[deploy-sse] SSM command: $CMD_ID"

for _ in $(seq 1 60); do
  sleep 5
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in Success|Failed|TimedOut|Cancelled) break ;; esac
done

echo "[deploy-sse] final status: $STATUS"
echo
echo "[deploy-sse] on-host output:"
aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>&1 | head -60

[ "$STATUS" = "Success" ] || exit 1

echo
echo "[deploy-sse] done — refresh https://splunk-poc.totallywild.ai/en-GB/app/Splunk_Security_Essentials/mitre_overview (filter Originating App = TotallyWildAi Detections)"
