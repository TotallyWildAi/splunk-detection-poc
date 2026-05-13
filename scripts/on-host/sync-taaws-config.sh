#!/usr/bin/env bash
# Runs ON the Splunk EC2 (via SSM). Reads compiled TA-aws config from S3
# and POSTs each row to the Splunk REST API at localhost:8089.
#
# Idempotent: POST to /<collection>/<name> first (update existing). On
# 404, fall back to POST to /<collection> with `name=` in the body (create).

set -uo pipefail

BUCKET="${1:?missing arg: bucket}"
KEY="${2:?missing arg: s3 key}"
SECRET_ARN="${3:?missing arg: secret arn}"
ADMIN_USER="${4:?missing arg: admin user}"
REGION="${5:?missing arg: region}"

PW=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" --query SecretString --output text)
if [ -z "$PW" ]; then echo "[sync-taaws] FAILED reading admin password" >&2; exit 1; fi

TMP=/tmp/taaws-config.json
aws s3 cp --region "$REGION" "s3://$BUCKET/$KEY" "$TMP" >/dev/null

# Delegate the actual writes to python — much cleaner than juggling shell
# quoting around curl --data-urlencode for stanzas with values containing
# colons, slashes, equals signs etc.
ADMIN_USER="$ADMIN_USER" PW="$PW" python3 - "$TMP" <<'PY'
import json, os, ssl, sys, urllib.parse, urllib.request, base64

path = sys.argv[1]
admin_user = os.environ["ADMIN_USER"]
pw = os.environ["PW"]
auth = base64.b64encode(f"{admin_user}:{pw}".encode()).decode()
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
BASE = "https://localhost:8089/servicesNS/nobody/Splunk_TA_aws"

doc = json.load(open(path))
accounts = doc.get("accounts", [])
inputs = doc.get("inputs", [])

ok = fail = 0

def http(method: str, url: str, body: dict | None = None) -> tuple[int, str]:
    data = urllib.parse.urlencode(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        return resp.status, resp.read().decode(errors="replace")[:300]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]
    except Exception as e:
        return 0, f"{e!r}"

# Accounts use a check-then-create pattern. TA-aws's account update handler
# rejects most fields (including `iam`) once an account exists; the create
# endpoint accepts the full param set. So on an existing account we
# verify-and-skip; on a missing one we create.
for row in accounts:
    coll, name, params = row["collection"], row["name"], dict(row["params"])
    check_url = f"{BASE}/{coll}/{urllib.parse.quote(name, safe='')}"
    code, _ = http("GET", check_url)
    if code == 200:
        print(f"  OK     {coll}/{name} already exists (skipping update — TA-aws account handler is create-only after first save)")
        ok += 1
        continue
    if code == 404:
        code, body = http("POST", f"{BASE}/{coll}", params)
        if code in (200, 201):
            print(f"  CREATE {coll}/{name} ok")
            ok += 1
            continue
    print(f"  FAIL   {coll}/{name} HTTP {code}\n    response: {body[:200]}")
    fail += 1

# Inputs use GET-first to determine update-vs-create. Splunk's input REST
# handler is inconsistent about which HTTP code it returns when the entity
# doesn't exist: GET returns 404, but POST to /<coll>/<name> for a
# non-existent input returns 400 with "Cannot edit ... because it does
# not exist". The 400 trips up a try-update-then-create-on-404 pattern,
# so we check existence explicitly. The update endpoint accepts the full
# param set EXCEPT `name` (which lives in the URL path) and `disabled`
# (which has its own /enable + /disable endpoints, not the standard
# update body).
for row in inputs:
    coll, name, params = row["collection"], row["name"], dict(row["params"])
    update_body = {k: v for k, v in params.items() if k != "name"}
    create_body = params
    check_url = f"{BASE}/{coll}/{urllib.parse.quote(name, safe='')}"

    code, body = http("GET", check_url)
    if code == 200:
        code, body = http("POST", check_url, update_body)
        if code in (200, 201):
            print(f"  UPDATE {coll}/{name} ok")
            ok += 1
            continue
    elif code == 404:
        code, body = http("POST", f"{BASE}/{coll}", create_body)
        if code in (200, 201):
            print(f"  CREATE {coll}/{name} ok")
            ok += 1
            continue
    print(f"  FAIL   {coll}/{name} HTTP {code}\n    response: {body[:200]}")
    fail += 1

print(f"\n[sync-taaws] wrote {ok}, failed {fail}")
sys.exit(1 if fail else 0)
PY
