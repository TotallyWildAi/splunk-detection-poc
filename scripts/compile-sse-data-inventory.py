#!/usr/bin/env python3
"""Compile sse-config/data-inventory.yml into PATCH bodies for SSE's
`data_inventory_products` KV-store collection.

For each product entry in the YAML we emit a `{_key, patch}` row that
the on-host writer will apply with HTTP POST to:

    /servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/data_inventory_products/<_key>

We do NOT create new rows — every productId we reference must already
exist (SSE ships ~291 product rows covering common security products).
What we do is patch existing rows to set their state machine fields
into the `success` terminal state.
"""

from __future__ import annotations
import json, os, sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required: pip install pyyaml\n")
    sys.exit(2)


# All four state-machine steps marked successful. SSE's internal worker
# normally drives this asynchronously; we're short-circuiting it.
TERMINAL_JSON_STATUS = json.dumps({
    "init":            {"status": "success"},
    "step-sourcetype": {"status": "success"},
    "step-eventsize":  {"status": "success"},
    "step-volume":     {"status": "success"},
})


def main() -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    path = os.path.join(root, "sse-config", "data-inventory.yml")

    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)

    rows = []
    for prod in doc.get("products") or []:
        _key = prod["product_id"]
        # The patch body: only fields we want to override. SSE preserves
        # other fields (productName, vendorName, eventtypeId, etc) because
        # the POST is a partial update.
        patch = {
            "status":     "success",
            "stage":      "step-volume",
            "jsonStatus": TERMINAL_JSON_STATUS,
            # coverage_level drives the percentage shown in dashboards;
            # 100 = "we have all the expected fields for this data source".
            # SSE will overwrite this with a real computed value on its
            # next run; we set it as a sensible default.
            "coverage_level": "100",
        }
        # Optional helpers — sourcetype + index inform basesearch / termsearch
        # if SSE re-discovers later.
        if "sourcetype" in prod and "index" in prod:
            bs = f'index="{prod["index"]}" sourcetype="{prod["sourcetype"]}" '
            patch["basesearch"] = bs
            patch["termsearch"] = bs

        rows.append({"_key": _key, "patch": patch})
        sys.stderr.write(f"ok: {_key}\n")

    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.stderr.write(f"\n{len(rows)} data-inventory rows compiled\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
