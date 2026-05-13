#!/usr/bin/env bash
# Compile detections/*.yml -> Splunk REST saved-search payloads, upload to
# S3 alongside the on-host writer script, then SSM-trigger the writer.
#
# Phase 5 — the headline Detections-as-Code capability. Runs from local
# dev AND from CI (same script). Pattern mirrors deploy-sse-custom-content.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

REGION=${AWS_REGION:-ap-southeast-2}
TF_DIR="terraform"
CONTENT_KEY="detections/detection-searches.json"
SCRIPT_KEY="detections/sync-detection-searches.sh"
SPLUNK_APP="tw_cim_accel"

for bin in terraform aws python3; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin not in PATH" >&2; exit 1; }
done

BUCKET=$(terraform -chdir="$TF_DIR" output -raw splunk_apps_bucket)
INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw splunk_instance_id)
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_password_secret_arn)
ADMIN_USER=$(terraform -chdir="$TF_DIR" output -raw splunk_admin_email)

echo "[deploy-detections] bucket: $BUCKET"
echo "[deploy-detections] instance: $INSTANCE_ID"
echo "[deploy-detections] target app: $SPLUNK_APP"
echo

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[deploy-detections] compiling detections/*.yml -> saved-search payloads"
python3 scripts/compile-detections-to-savedsearches.py > "$STAGE/detection-searches.json"
NUM=$(grep -c '"name"' "$STAGE/detection-searches.json" || echo 0)
echo "[deploy-detections] compiled $NUM saved-searches"

echo
echo "[deploy-detections] uploading payload + on-host script to s3://$BUCKET/detections/"
aws s3 cp "$STAGE/detection-searches.json"           "s3://$BUCKET/$CONTENT_KEY" --region "$REGION"
aws s3 cp scripts/on-host/sync-detection-searches.sh "s3://$BUCKET/$SCRIPT_KEY"  --region "$REGION"

PAYLOAD_FILE=$(mktemp); trap 'rm -rf "$STAGE" "$PAYLOAD_FILE"' EXIT
python3 - "$BUCKET" "$CONTENT_KEY" "$SCRIPT_KEY" "$SECRET_ARN" "$ADMIN_USER" "$REGION" "$INSTANCE_ID" "$SPLUNK_APP" > "$PAYLOAD_FILE" <<'PYEND'
import json, sys
bucket, content_key, script_key, secret_arn, admin_user, region, instance_id, app = sys.argv[1:9]
cmd = (
    f"aws s3 cp --region '{region}' 's3://{bucket}/{script_key}' /tmp/sync-detection-searches.sh && "
    f"chmod +x /tmp/sync-detection-searches.sh && "
    f"/tmp/sync-detection-searches.sh '{bucket}' '{content_key}' '{secret_arn}' '{admin_user}' '{region}' '{app}'"
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
echo "[deploy-detections] sending SSM command"
CMD_ID=$(aws ssm send-command --cli-input-json "$PAYLOAD_URI" --region "$REGION" --query 'Command.CommandId' --output text)
echo "[deploy-detections] SSM command: $CMD_ID"

for _ in $(seq 1 60); do
  sleep 5
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in Success|Failed|TimedOut|Cancelled) break ;; esac
done

echo "[deploy-detections] final status: $STATUS"
echo
echo "[deploy-detections] on-host output:"
aws ssm list-command-invocations --command-id "$CMD_ID" --region "$REGION" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text 2>&1 | head -80

[ "$STATUS" = "Success" ] || exit 1

echo
echo "[deploy-detections] done — scheduled searches now live at"
echo "  https://splunk-poc.totallywild.ai/en-GB/manager/$SPLUNK_APP/saved/searches"
