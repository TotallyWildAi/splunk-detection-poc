#!/usr/bin/env bash
# Runs ON the Splunk EC2 (via SSM). Reads compiled SSE Data Inventory
# patches from S3 and applies each one via REST POST.
#
# Invocation:
#   bash /tmp/sync-sse-data-inventory.sh <s3-bucket> <s3-key> <secret-arn> <admin-user> <region>

set -uo pipefail

BUCKET="${1:?missing arg: bucket}"
KEY="${2:?missing arg: s3 key}"
SECRET_ARN="${3:?missing arg: secret arn}"
ADMIN_USER="${4:?missing arg: admin user}"
REGION="${5:?missing arg: region}"

PW=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)
if [ -z "$PW" ]; then echo "[sync-di] FAILED reading admin password" >&2; exit 1; fi

TMP=/tmp/sse-data-inventory.json
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
BASE = "https://localhost:8089/servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/data_inventory_products"

rows = json.load(open(path))
ok = fail = skip = 0

for row in rows:
    key = row["_key"]
    patch = row["patch"]
    url = f"{BASE}/{urllib.parse.quote(key, safe='')}"
    # Verify the row exists. We only patch existing rows; we don't
    # create new product entries (SSE owns those definitions).
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    try:
        urllib.request.urlopen(req, context=ctx, timeout=15)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"  SKIP {key} (no such product row in SSE — not patching)")
            skip += 1
            continue
        print(f"  FAIL {key} pre-check HTTP {e.code}")
        fail += 1
        continue

    # The KV-store data endpoint accepts a JSON body for partial updates.
    body = json.dumps(patch).encode()
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
        },
    )
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        if resp.status in (200, 201):
            print(f"  PATCH {key} ok (status={patch.get('status')})")
            ok += 1
        else:
            print(f"  FAIL  {key} HTTP {resp.status}")
            fail += 1
    except Exception as e:
        print(f"  FAIL  {key} {e!r}")
        fail += 1

print(f"\n[sync-di] patched {ok}, skipped {skip}, failed {fail}")
sys.exit(1 if fail else 0)
PY
