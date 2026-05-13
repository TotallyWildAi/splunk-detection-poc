#!/usr/bin/env python3
"""Compile detections/**/*.yml into Splunk REST saved-search payloads.

Output: a JSON document on stdout, an array of `{name, params}` rows. The
downstream uploader posts each row's `params` dict (form-urlencoded) to:

    /servicesNS/nobody/<app>/saved/searches            (POST, create)
    /servicesNS/nobody/<app>/saved/searches/<name>     (POST, update)

Each detection becomes one scheduled saved search. The naming convention is:

    TWAi - <detection.name> - Rule

Phase 4.5's SSE Custom Content compiler uses the same convention so the
SSE detail panel's "Search Name" link resolves to a real saved search on
the SH.
"""

from __future__ import annotations

import glob
import json
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required: pip install pyyaml\n")
    sys.exit(2)


# ─── Mapping tables ────────────────────────────────────────────────────

# Splunk alert.severity is an integer 1-6.
#   1=informational  2=low  3=medium  4=high  5=critical  6=fatal
SEVERITY_MAP = {
    "informational": 1,
    "low":           2,
    "medium":        3,
    "high":          4,
    "critical":      5,
}


def impact_to_severity_int(impact: int | None) -> int:
    if impact is None: return 3
    if impact >= 90: return 5  # critical
    if impact >= 75: return 4  # high
    if impact >= 50: return 3  # medium
    if impact >= 25: return 2  # low
    return 1                   # informational


def saved_search_name(detection_name: str) -> str:
    """Same convention as the SSE compiler. Keep these aligned — SSE links
    detection rows to saved searches by exact name match."""
    return f"TWAi - {detection_name} - Rule"


def compile_one(doc: dict) -> dict:
    name = saved_search_name(doc["name"])
    tags = doc.get("tags") or {}

    severity = impact_to_severity_int(tags.get("impact"))
    is_scheduled = doc.get("type") != "Hunting"  # Hunting types run on-demand

    # Default schedule: every 15 minutes covering the last 5 minutes. Burst
    # detections override to a wider window (handled per-detection if needed
    # via a custom `schedule` block — not in our YAML schema yet, so we use
    # the default for all scheduled rules).
    cron_schedule = "*/15 * * * *"
    dispatch_earliest = "-5m@m"
    dispatch_latest = "now"

    # Alert config: fire when the search returns any event. Splunk's
    # saved-search API has two alert-condition forms:
    #   (a) alert_type=number of events + alert_comparator + alert_threshold
    #   (b) alert_type=custom + alert_condition (an SPL fragment)
    # We use (b) — `search count > 0` is a portable any-result trigger.
    alert_track = 1
    alert_condition = "search count > 0"

    # Build action / metadata fields ATT&CK + analytic_story etc. get stored
    # as comma-separated tag strings so the saved-search UI surface stays
    # readable. The CIS/NIST fields go into `description` as a trailing
    # block so an analyst inspecting the search sees the compliance mapping.
    mitre_techniques = ",".join(tags.get("mitre_attack_id") or [])
    kill_chain = ",".join(tags.get("kill_chain_phases") or [])
    analytic_story = ",".join(tags.get("analytic_story") or [])

    description_full = (doc.get("description") or "").strip()
    if doc.get("how_to_implement"):
        description_full += "\n\nHow to implement: " + doc["how_to_implement"].strip()
    if doc.get("known_false_positives"):
        description_full += "\n\nKnown false positives: " + doc["known_false_positives"].strip()
    if mitre_techniques:
        description_full += f"\n\nMITRE ATT&CK: {mitre_techniques}"
    if analytic_story:
        description_full += f"\nAnalytic story: {analytic_story}"

    params = {
        "name":                          name,
        "search":                        (doc.get("search") or "").strip(),
        "description":                   description_full,
        "is_scheduled":                  "1" if is_scheduled else "0",
        "cron_schedule":                 cron_schedule if is_scheduled else "",
        "dispatch.earliest_time":        dispatch_earliest,
        "dispatch.latest_time":          dispatch_latest,
        "alert_type":                    "custom",
        "alert.track":                   str(alert_track),
        "alert.severity":                str(severity),
        "alert_condition":               alert_condition,
        "alert.suppress":                "0",
        "actions":                       "",  # no auto-email/webhook in POC — wire in Phase 7
        "disabled":                      "0",
        "request.ui_dispatch_app":       "tw_cim_accel",
        "request.ui_dispatch_view":      "search",
    }

    return {"name": name, "params": params, "id": doc["id"]}


def main() -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    pattern = os.path.join(root, "detections", "**", "*.yml")

    rows = []
    fail = 0
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path, encoding="utf-8") as f:
                doc = yaml.safe_load(f)
        except Exception as e:
            sys.stderr.write(f"FAIL parse {path}: {e}\n")
            fail += 1
            continue
        if not isinstance(doc, dict):
            sys.stderr.write(f"FAIL not a dict {path}\n")
            fail += 1
            continue
        try:
            rows.append(compile_one(doc))
            sys.stderr.write(f"ok: {os.path.relpath(path, root)} -> {rows[-1]['name']}\n")
        except KeyError as e:
            sys.stderr.write(f"FAIL missing field {path}: {e}\n")
            fail += 1

    if fail:
        sys.stderr.write(f"\n{fail} compile failures — aborting\n")
        return 1

    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.stderr.write(f"\n{len(rows)} detections compiled to saved-search payloads\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
