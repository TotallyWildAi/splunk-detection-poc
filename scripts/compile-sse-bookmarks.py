#!/usr/bin/env python3
"""Compile detections/**/*.yml into SSE bookmark rows.

For every detection in the repo, emit a `bookmark` KV-store row marking
it as `status: successfullyImplemented`. This populates SSE's "Active"
count in the MITRE ATT&CK heat map and "Coverage" dashboards — without
these bookmark rows the merged ShowcaseInfo entries fall back to
`bookmark_status: none`, which counts as Total but NOT Active.

Output: JSON array on stdout, one row per detection, ready for the
on-host writer to PUT/POST against:

    /servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/bookmark/<_key>

Schema (from Splunk_Security_Essentials/default/collections.conf, [bookmark]):
    _key          KV-store primary key (we use the detection UUID)
    showcase_name KV column SSE keys on when building its bookmarks dict
                  (must equal showcaseId in custom_content)
    status        bookmarked | successfullyImplemented | inQueue | ...
    user          bookmarker identity (informational)
    notes         optional free-text (we leave empty)
    _time         creation timestamp (KV-store sets automatically on
                  insert; we pass our own anyway for portability)
"""

from __future__ import annotations
import glob, json, os, sys, time

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required\n")
    sys.exit(2)


def main() -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    pattern = os.path.join(root, "detections", "**", "*.yml")
    now = int(time.time())

    rows = []
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path, encoding="utf-8") as f:
                doc = yaml.safe_load(f)
        except Exception as e:
            sys.stderr.write(f"FAIL parse {path}: {e}\n")
            return 1
        if not isinstance(doc, dict) or "id" not in doc:
            sys.stderr.write(f"FAIL no id in {path}\n")
            return 1

        rows.append({
            "_key":          doc["id"],
            "showcase_name": doc["id"],
            "status":        "successfullyImplemented",
            "user":          "cicd",
            "notes":         f"Auto-bookmarked by detections-as-code CI for {doc.get('name','')}",
            "_time":         now,
        })
        sys.stderr.write(f"ok: {os.path.relpath(path, root)} -> bookmark for {doc['id']}\n")

    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.stderr.write(f"\n{len(rows)} bookmark rows compiled\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
