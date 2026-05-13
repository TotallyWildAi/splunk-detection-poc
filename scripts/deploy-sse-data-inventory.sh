#!/usr/bin/env bash
# Compile sse-config/data-inventory.yml -> patch rows, upload to S3,
# SSM-trigger the on-host writer. Same pattern as deploy-detections.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

REGION=${AWS_REGION:-ap-southeast-2}
TF_DIR="terraform"
CONTENT_KEY="sse-content/data-inventory.json"
SCRIPT_KEY="sse-content/sync-sse-data-inventory.sh"

for bin in terraform aws python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not in PATH" >&2; exit 1; }
done

BUCKET=$(terraform -chdir="$TF_DIR" output -raw splunk_apps_bucket)
INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw splunk_instance_id)
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_password_secret_arn)
ADMIN_USER=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_email)

echo "[deploy-di] bucket: $BUCKET"
echo "[deploy-di] instance: $INSTANCE_ID"
echo

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT

echo "[deploy-di] compiling sse-config/data-inventory.yml -> patch rows"
python3 scripts/compile-sse-data-inventory.py > "$STAGE/data-inventory.json"

echo
echo "[deploy-di] uploading payload + on-host script to s3://$BUCKET/sse-content/"
aws s3 cp "$STAGE/data-inventory.json"                "s3://$BUCKET/$CONTENT_KEY" --region "$REGION"
aws s3 cp scripts/on-host/sync-sse-data-inventory.sh  "s3://$BUCKET/$SCRIPT_KEY"  --region "$REGION"

PAYLOAD_FILE=$(mktemp); trap 'rm -rf "$STAGE" "$PAYLOAD_FILE"' EXIT
python3 - "$BUCKET" "$CONTENT_KEY" "$SCRIPT_KEY" "$SECRET_ARN" "$ADMIN_USER" "$REGION" "$INSTANCE_ID" > "$PAYLOAD_FILE" <<'PYEND'
import json, sys
bucket, content_key, script_key, secret_arn, admin_user, region, instance_id = sys.argv[1:8]
cmd = (
    f"aws s3 cp --region '{region}' 's3://{bucket}/{script_key}' /tmp/sync-sse-data-inventory.sh && "
    f"chmod +x /tmp/sync-sse-data-inventory.sh && "
    f"/tmp/sync-sse-data-inventory.sh '{bucket}' '{content_key}' '{secret_arn}' '{admin_user}' '{region}'"
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
echo "[deploy-di] sending SSM command"
CMD_ID=$(aws ssm send-command --cli-input-json "$PAYLOAD_URI" --region "$REGION" --query 'Command.CommandId' --output text)
echo "[deploy-di] SSM command: $CMD_ID"

for _ in $(seq 1 60); do
  sleep 5
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in Success|Failed|TimedOut|Cancelled) break ;; esac
done

echo "[deploy-di] final status: $STATUS"
echo
aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>&1 | head -30

[ "$STATUS" = "Success" ] || exit 1
echo
echo "[deploy-di] done — refresh https://splunk-poc.totallywild.ai/en-GB/app/Splunk_Security_Essentials/sse_cim_compliance"
