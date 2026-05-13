#!/usr/bin/env bash
# Runs ON the Splunk EC2 (via SSM). Reads compiled SSE bookmark rows from S3
# and PUTs each into SSE's `bookmark` KV collection.
#
# Invocation:
#   bash /tmp/sync-sse-bookmarks.sh <s3-bucket> <s3-key> <secret-arn> <admin-user> <region>

set -uo pipefail

BUCKET="${1:?missing arg: bucket}"
KEY="${2:?missing arg: s3 key}"
SECRET_ARN="${3:?missing arg: secret arn}"
ADMIN_USER="${4:?missing arg: admin user}"
REGION="${5:?missing arg: region}"

PW=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)
if [ -z "$PW" ]; then echo "[sync-bookmarks] FAILED reading admin password" >&2; exit 1; fi

TMP=/tmp/sse-bookmarks.json
aws s3 cp --region "$REGION" "s3://$BUCKET/$KEY" "$TMP" >/dev/null

ADMIN_USER="$ADMIN_USER" PW="$PW" python3 - "$TMP" <<'PY'
import json, os, ssl, sys, urllib.parse, urllib.request, base64

path = sys.argv[1]
admin_user = os.environ["ADMIN_USER"]
pw = os.environ["PW"]
auth = base64.b64encode(f"{admin_user}:{pw}".encode()).decode()
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
BASE = "https://localhost:8089/servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/bookmark"

def post(url, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
    )
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        return resp.status, resp.read().decode(errors="replace")[:300]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]
    except Exception as e:
        return 0, f"{e!r}"

rows = json.load(open(path))
ok = fail = 0
for row in rows:
    key = row["_key"]
    # Try update first; fall through to create on 404.
    update_url = f"{BASE}/{urllib.parse.quote(key, safe='')}"
    code, body = post(update_url, row)
    if code in (200, 201):
        print(f"  PUT  {key} ok")
        ok += 1
        continue
    if code == 404:
        code, body = post(BASE, row)
        if code in (200, 201):
            print(f"  POST {key} ok (created)")
            ok += 1
            continue
    print(f"  FAIL {key} HTTP {code}: {body[:120]}")
    fail += 1

print(f"\n[sync-bookmarks] wrote {ok}, failed {fail}")
sys.exit(1 if fail else 0)
PY

# Bust the SSE ShowcaseInfo cache so the heat map picks up the new
# bookmark status without a Splunk restart.
curl -ks -u "$ADMIN_USER:$PW" 'https://localhost:8089/servicesNS/nobody/Splunk_Security_Essentials/SSEShowcaseInfo' >/dev/null \
  && echo "[sync-bookmarks] cache rebuilt" \
  || echo "[sync-bookmarks] cache rebuild non-zero (rows still applied)"
