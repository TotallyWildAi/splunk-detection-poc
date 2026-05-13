#!/usr/bin/env bash
# Compile detections/*.yml -> SSE bookmark rows, upload to S3, SSM-trigger
# the on-host writer. Marks every detection as `successfullyImplemented`
# in SSE's bookmark collection, which is what drives the "Active" count
# on the MITRE ATT&CK heat map.

set -euo pipefail
cd "$(dirname "$0")/.."

REGION=${AWS_REGION:-ap-southeast-2}
TF_DIR="terraform"
CONTENT_KEY="sse-content/bookmarks.json"
SCRIPT_KEY="sse-content/sync-sse-bookmarks.sh"

for bin in terraform aws python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not in PATH" >&2; exit 1; }
done

BUCKET=$(terraform -chdir="$TF_DIR" output -raw splunk_apps_bucket)
INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw splunk_instance_id)
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_password_secret_arn)
ADMIN_USER=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_email)

echo "[deploy-bookmarks] bucket: $BUCKET, instance: $INSTANCE_ID"

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT

echo "[deploy-bookmarks] compiling detections/*.yml -> bookmark rows"
python3 scripts/compile-sse-bookmarks.py > "$STAGE/bookmarks.json"

echo "[deploy-bookmarks] uploading to s3://$BUCKET/sse-content/"
aws s3 cp "$STAGE/bookmarks.json"                "s3://$BUCKET/$CONTENT_KEY" --region "$REGION"
aws s3 cp scripts/on-host/sync-sse-bookmarks.sh  "s3://$BUCKET/$SCRIPT_KEY"  --region "$REGION"

PAYLOAD_FILE=$(mktemp); trap 'rm -rf "$STAGE" "$PAYLOAD_FILE"' EXIT
python3 - "$BUCKET" "$CONTENT_KEY" "$SCRIPT_KEY" "$SECRET_ARN" "$ADMIN_USER" "$REGION" "$INSTANCE_ID" > "$PAYLOAD_FILE" <<'PYEND'
import json, sys
bucket, content_key, script_key, secret_arn, admin_user, region, instance_id = sys.argv[1:8]
cmd = (
    f"aws s3 cp --region '{region}' 's3://{bucket}/{script_key}' /tmp/sync-sse-bookmarks.sh && "
    f"chmod +x /tmp/sync-sse-bookmarks.sh && "
    f"/tmp/sync-sse-bookmarks.sh '{bucket}' '{content_key}' '{secret_arn}' '{admin_user}' '{region}'"
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

CMD_ID=$(aws ssm send-command --cli-input-json "$PAYLOAD_URI" --region "$REGION" --query 'Command.CommandId' --output text)
echo "[deploy-bookmarks] SSM command: $CMD_ID"

for _ in $(seq 1 60); do
  sleep 5
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in Success|Failed|TimedOut|Cancelled) break ;; esac
done

echo "[deploy-bookmarks] final status: $STATUS"
aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>&1 | head -30

[ "$STATUS" = "Success" ] || exit 1
