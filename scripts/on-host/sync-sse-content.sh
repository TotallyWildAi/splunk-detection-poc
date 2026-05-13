#!/usr/bin/env bash
# Runs ON the Splunk EC2 (via SSM). Reads custom_content.json from S3 and
# writes each row into Splunk Security Essentials' `custom_content`
# KV-store collection via the local management port (no public 8089 exposure).
#
# Invocation:
#   bash /tmp/sync-sse-content.sh <s3-bucket> <s3-key> <secret-arn> <admin-user> <region>
#
# Idempotent: PUT to /<_key> first (update), POST to the collection root on
# 404 (create). After all writes, hits the SSEShowcaseInfo cache-rebuild
# endpoint so dashboards refresh without a Splunk restart.

set -uo pipefail

BUCKET="${1:?missing arg: bucket}"
KEY="${2:?missing arg: s3 key}"
SECRET_ARN="${3:?missing arg: secret arn}"
ADMIN_USER="${4:?missing arg: admin user}"
REGION="${5:?missing arg: region}"

PW=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)
if [ -z "$PW" ]; then
  echo "[sync-sse] FAILED reading admin password from $SECRET_ARN" >&2
  exit 1
fi

TMP=/tmp/sse-custom-content.json
aws s3 cp --region "$REGION" "s3://$BUCKET/$KEY" "$TMP" >/dev/null

BASE='https://localhost:8089/servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/custom_content'

OK=0
FAIL=0
# Emit one row per line as a JSON string, then iterate.
while IFS= read -r row; do
  row_key=$(echo "$row" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["_key"])')
  status=$(curl -ks -u "$ADMIN_USER:$PW" -X PUT -H 'Content-Type: application/json' -d "$row" "$BASE/$row_key" -w '%{http_code}' -o /dev/null)
  if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    echo "  PUT  $row_key ok"
    OK=$((OK+1))
    continue
  fi
  if [ "$status" = "404" ]; then
    status=$(curl -ks -u "$ADMIN_USER:$PW" -X POST -H 'Content-Type: application/json' -d "$row" "$BASE" -w '%{http_code}' -o /dev/null)
    if [ "$status" = "200" ] || [ "$status" = "201" ]; then
      echo "  POST $row_key ok (created)"
      OK=$((OK+1))
      continue
    fi
  fi
  echo "  FAIL $row_key HTTP $status"
  FAIL=$((FAIL+1))
done < <(python3 -c 'import sys,json; [print(json.dumps(r)) for r in json.load(open("'"$TMP"'"))]')

echo
echo "[sync-sse] wrote $OK rows, $FAIL failures"

# Bust the ShowcaseInfo cache so dashboards reflect the new rows immediately.
curl -ks -u "$ADMIN_USER:$PW" 'https://localhost:8089/servicesNS/nobody/Splunk_Security_Essentials/SSEShowcaseInfo' >/dev/null \
  && echo "[sync-sse] cache rebuilt" \
  || echo "[sync-sse] cache rebuild returned non-zero (rows still applied)"

[ "$FAIL" -eq 0 ]
