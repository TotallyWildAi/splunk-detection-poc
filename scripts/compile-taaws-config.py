#!/usr/bin/env python3
"""Compile taaws-config/config.yml into TA-aws REST payloads.

Output: a JSON document on stdout with two arrays — `accounts` and
`inputs`. Each row is `{collection, name, params}` so the on-host
writer knows which REST endpoint to hit.

Endpoint pattern:
  accounts: /servicesNS/nobody/Splunk_TA_aws/splunk_ta_aws_aws_account[/<name>]
  inputs (aws_sqs_based_s3):
            /servicesNS/nobody/Splunk_TA_aws/data/inputs/aws_sqs_based_s3[/<name>]
"""

from __future__ import annotations
import json, os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required: pip install pyyaml\n")
    sys.exit(2)

ACCOUNT_COLLECTION = "splunk_ta_aws_aws_account"
INPUT_BASE = "data/inputs"


def main() -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    path = os.path.join(root, "taaws-config", "config.yml")

    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)

    accounts = []
    for acct in doc.get("accounts") or []:
        if "name" not in acct:
            sys.stderr.write(f"FAIL account missing name: {acct}\n")
            return 1
        # Stringify everything — Splunk's REST API expects form values, so
        # ints become strings.
        params = {k: str(v) for k, v in acct.items()}
        accounts.append({
            "collection": ACCOUNT_COLLECTION,
            "name":       acct["name"],
            "params":     params,
        })
        sys.stderr.write(f"ok: account {acct['name']}\n")

    inputs = []
    for input_kind, items in (doc.get("inputs") or {}).items():
        for inp in items:
            if "name" not in inp:
                sys.stderr.write(f"FAIL input missing name: {inp}\n")
                return 1
            params = {k: str(v) for k, v in inp.items()}
            inputs.append({
                "collection": f"{INPUT_BASE}/{input_kind}",
                "name":       inp["name"],
                "params":     params,
            })
            sys.stderr.write(f"ok: input {input_kind}/{inp['name']}\n")

    out = {"accounts": accounts, "inputs": inputs}
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.stderr.write(f"\n{len(accounts)} accounts, {len(inputs)} inputs compiled\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
