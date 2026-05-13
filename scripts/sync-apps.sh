#!/usr/bin/env bash
# Sync the Splunk app packages from ../splunk-apps/ to the S3 bucket,
# then trigger /opt/splunk-poc/install-apps.sh on the Splunk EC2 via SSM
# so the new packages are installed without a full instance reboot.
#
# Run from a developer machine that has:
#   - AWS credentials with permission to s3:PutObject on the apps bucket
#     and ssm:SendCommand on the Splunk EC2.
#   - Local copies of the app .tgz/.tar.gz/.spl/.zip files in ../splunk-apps/.
#
# Usage:  ./scripts/sync-apps.sh

set -euo pipefail

cd "$(dirname "$0")/.."

REGION=${AWS_REGION:-ap-southeast-2}
TF_DIR="terraform"
APPS_DIR="splunk-apps"
APPS_SRC_DIR="apps-src"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform CLI not found in PATH" >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found in PATH" >&2
  exit 1
fi

BUCKET=$(terraform -chdir="$TF_DIR" output -raw splunk_apps_bucket 2>/dev/null || true)
INSTANCE_ID=$(terraform -chdir="$TF_DIR" output -raw splunk_instance_id 2>/dev/null || true)

if [ -z "$BUCKET" ] || [ -z "$INSTANCE_ID" ]; then
  echo "Could not read terraform outputs. Has 'terraform apply' been run?" >&2
  exit 1
fi

echo "[sync-apps] bucket: $BUCKET"
echo "[sync-apps] instance: $INSTANCE_ID"
echo "[sync-apps] region: $REGION"
echo

# ─── Build .tgz from each subdir of apps-src/ ─────────────────────────
# apps-src/ holds our own first-party Splunk apps (versioned in git as
# unpacked directories). splunk-apps/ holds third-party .tgz/.spl files
# downloaded from Splunkbase (gitignored, since they're large binaries).
#
# We stage everything into a tmp dir and `aws s3 sync --delete` from
# there, so the bucket is a faithful mirror of both.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Copy third-party packages (if any).
shopt -s nullglob
for f in "$APPS_DIR"/*.tgz "$APPS_DIR"/*.tar.gz "$APPS_DIR"/*.spl "$APPS_DIR"/*.zip; do
  cp "$f" "$STAGE/"
done
shopt -u nullglob

# Build .tgz for each first-party app under apps-src/.
if [ -d "$APPS_SRC_DIR" ]; then
  for d in "$APPS_SRC_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    echo "[sync-apps] packaging $APPS_SRC_DIR/$name -> $name.tgz"
    tar -czf "$STAGE/$name.tgz" -C "$APPS_SRC_DIR" "$name"
  done
fi

echo
echo "[sync-apps] uploading staged packages -> s3://$BUCKET/"
aws s3 sync "$STAGE/" "s3://$BUCKET/" --region "$REGION" --delete

echo
echo "[sync-apps] triggering /opt/splunk-poc/install-apps.sh on $INSTANCE_ID"
CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "sync-apps.sh re-install" \
  --parameters 'commands=["bash /opt/splunk-poc/install-apps.sh"]' \
  --query 'Command.CommandId' --output text)

echo "[sync-apps] SSM command: $CMD_ID"
echo "[sync-apps] waiting for completion (up to 10 min)..."

# Poll
for _ in $(seq 1 120); do
  sleep 5
  STATUS=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  case "$STATUS" in
    Success|Failed|TimedOut|Cancelled) break ;;
  esac
done

echo "[sync-apps] final status: $STATUS"
if [ "$STATUS" != "Success" ]; then
  echo "[sync-apps] check /var/log/splunk-install-apps.log on the instance via SSM" >&2
  exit 1
fi

echo "[sync-apps] done"
