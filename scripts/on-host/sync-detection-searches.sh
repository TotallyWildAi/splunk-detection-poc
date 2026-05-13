#!/usr/bin/env bash
# Runs ON the Splunk EC2 (via SSM). Reads compiled saved-search payloads
# from S3 and creates/updates each one via /servicesNS/.../saved/searches.
#
# Invocation:
#   bash /tmp/sync-detection-searches.sh <s3-bucket> <s3-key> <secret-arn> <admin-user> <region> <splunk-app>
#
# Idempotent: POST to /saved/searches/<name> first (update). On 404, POST
# to /saved/searches (create). On HTTP 409 (already exists in another
# namespace) we treat as success and continue.

set -uo pipefail

BUCKET="${1:?missing arg: bucket}"
KEY="${2:?missing arg: s3 key}"
SECRET_ARN="${3:?missing arg: secret arn}"
ADMIN_USER="${4:?missing arg: admin user}"
REGION="${5:?missing arg: region}"
APP="${6:?missing arg: splunk app name}"

PW=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)
if [ -z "$PW" ]; then echo "[sync-detections] FAILED reading admin password" >&2; exit 1; fi

TMP=/tmp/detection-searches.json
aws s3 cp --region "$REGION" "s3://$BUCKET/$KEY" "$TMP" >/dev/null

BASE="https://localhost:8089/servicesNS/nobody/$APP/saved/searches"

OK=0
FAIL=0

# Each row is a JSON object with `name` + `params` (dict of saved-search
# REST params). Emit one row per line, then iterate.
while IFS= read -r row; do
  row_name=$(echo "$row" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["name"])')
  # URL-encode the name once for path use.
  name_enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$row_name")

  # Build the curl form-data args. Each param is `-d key=value`, value is
  # form-urlencoded by curl when we use --data-urlencode.
  curl_args=$(python3 - "$row" <<'PY'
import json, sys, shlex
row = json.loads(sys.argv[1])
for k, v in row["params"].items():
    print(f"--data-urlencode {shlex.quote(k + '=' + str(v))}")
PY
  )

  # 1) Try update at /saved/searches/<name_enc>. The `name` param is the
  # URL path, not a body field — omit it from --data-urlencode for update.
  update_args=$(echo "$curl_args" | grep -v -- '--data-urlencode '\''name=')

  status=$(eval curl -ks -u "'$ADMIN_USER:$PW'" -X POST $update_args \
    -w "'%{http_code}'" -o /tmp/curl-resp \
    "'$BASE/$name_enc'")

  if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    echo "  UPDATE $row_name ok"
    OK=$((OK+1))
    continue
  fi

  # 2) On 404 fall through to create.
  if [ "$status" = "404" ]; then
    status=$(eval curl -ks -u "'$ADMIN_USER:$PW'" -X POST $curl_args \
      -w "'%{http_code}'" -o /tmp/curl-resp \
      "'$BASE'")
    if [ "$status" = "200" ] || [ "$status" = "201" ]; then
      echo "  CREATE $row_name ok"
      OK=$((OK+1))
      continue
    fi
  fi

  echo "  FAIL   $row_name HTTP $status"
  echo "    response: $(head -c 300 /tmp/curl-resp 2>/dev/null)"
  FAIL=$((FAIL+1))
done < <(python3 -c 'import sys,json; [print(json.dumps(r)) for r in json.load(open("'"$TMP"'"))]')

echo
echo "[sync-detections] wrote $OK, failed $FAIL"

[ "$FAIL" -eq 0 ]
