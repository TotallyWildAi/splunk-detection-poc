#!/usr/bin/env python3
"""Compile detections/**/*.yml into Splunk Security Essentials Custom Content
(ShowcaseInfo) rows, ready to write into the SSE KV-store collection
`custom_content`.

Output: a single JSON document on stdout, an array of `{_key, json}` rows.

The downstream uploader (`scripts/deploy-sse-custom-content.sh`) reads this
document and PUTs/POSTs each row to:

    /servicesNS/nobody/Splunk_Security_Essentials/storage/collections/data/custom_content

Schema reference: SSE 3.8 ShowcaseInfo schema docs at help.splunk.com.
"""

from __future__ import annotations

import glob
import json
import os
import sys
from typing import Any

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML required: pip install pyyaml\n")
    sys.exit(2)


# ─── Mapping tables ────────────────────────────────────────────────────

# ATT&CK tactic name -> TA-code. SSE uses the bare TA codes pipe-delimited.
TACTIC_MAP = {
    "Initial Access":       "TA0001",
    "Execution":            "TA0002",
    "Persistence":          "TA0003",
    "Privilege Escalation": "TA0004",
    "Defense Evasion":      "TA0005",
    "Credential Access":    "TA0006",
    "Discovery":            "TA0007",
    "Lateral Movement":     "TA0008",
    "Collection":           "TA0009",
    "Exfiltration":         "TA0010",
    "Command and Control":  "TA0011",
    "Impact":               "TA0040",
}

# Our YAML's data_source slugs -> SSE data_source_categories IDs. These IDs
# drive the "Available" colour on the heat map (lit when the source is
# onboarded). Add entries as we ingest more data sources.
DATA_SOURCE_MAP = {
    "aws_cloudtrail": "DS0025CloudService",
    "aws_vpcflow":    "DS0029NetworkTraffic",
}

# Kill chain ATT&CK tactic -> Lockheed Martin phase, for the optional
# `killchain` field. Most ATT&CK tactics map to "Actions on Objectives"
# (post-exploitation); only the early-stage ones map cleanly.
KILLCHAIN_MAP = {
    "Initial Access":       "Delivery",
    "Execution":            "Exploitation",
    "Persistence":          "Installation",
    "Privilege Escalation": "Installation",
    "Defense Evasion":      "Actions on Objectives",
    "Credential Access":    "Actions on Objectives",
    "Discovery":            "Actions on Objectives",
    "Lateral Movement":     "Actions on Objectives",
    "Collection":           "Actions on Objectives",
    "Exfiltration":         "Actions on Objectives",
    "Command and Control":  "Command and Control",
    "Impact":               "Actions on Objectives",
}

# Constants shared across every row so SSE filters group them together.
DISPLAYAPP = "TotallyWildAi Detections"
CHANNEL = "totallywildai"


def impact_to_severity(impact: int | None) -> str:
    """Map YAML `tags.impact` (0-100) to SSE `severity`."""
    if impact is None:
        return "medium"
    if impact >= 90: return "critical"
    if impact >= 75: return "high"
    if impact >= 50: return "medium"
    if impact >= 25: return "low"
    return "informational"


def detection_type_to_domain(t: str | None) -> str:
    """YAML `type` (TTP/Anomaly/Hunting) -> SSE `domain`. SSE wants one of
    Access/Network/Endpoint/Threat/Other. Our content is overwhelmingly
    threat-monitoring shaped, so default to Threat."""
    return "Threat"


def detection_type_to_journey(t: str | None) -> str:
    """YAML `type` -> SSE `journey` (Stage_1..Stage_4). Stages map roughly
    to detection maturity. TTP = mature, Anomaly = stage 3 (ML/baseline),
    Hunting = stage 4 (analyst-driven)."""
    if t == "TTP":      return "Stage_2"
    if t == "Anomaly":  return "Stage_3"
    if t == "Hunting":  return "Stage_4"
    return "Stage_2"


def pipe_join(values: list[Any] | None) -> str:
    if not values:
        return ""
    return "|".join(str(v) for v in values)


def yaml_to_showcase(doc: dict[str, Any]) -> dict[str, Any]:
    """Render one detection YAML into a ShowcaseInfo JSON dict ready to be
    stringified into the `json` column of `custom_content`."""
    tags = doc.get("tags") or {}

    technique = pipe_join(tags.get("mitre_attack_id"))
    tactics = [TACTIC_MAP.get(p, "") for p in tags.get("kill_chain_phases") or []]
    tactics = [t for t in tactics if t]
    tactic = pipe_join(tactics)

    killchains = [KILLCHAIN_MAP.get(p, "") for p in tags.get("kill_chain_phases") or []]
    killchains = [k for k in killchains if k]
    killchain = pipe_join(killchains)

    data_source_categories = pipe_join([
        DATA_SOURCE_MAP[ds] for ds in (doc.get("data_source") or [])
        if ds in DATA_SOURCE_MAP
    ])

    severity = impact_to_severity(tags.get("impact"))

    # Compile saved-search name from detection name. Phase 5's REST deployer
    # will use the same convention when pushing /services/saved/searches.
    search_name = f"TWAi - {doc['name']} - Rule"

    showcase = {
        "id": doc["id"],
        "name": doc["name"],
        "description": (doc.get("description") or "").strip(),
        "domain": detection_type_to_domain(doc.get("type")),
        "usecase": "Security Monitoring",
        "category": pipe_join(tags.get("analytic_story")) or "AWS",
        "journey": detection_type_to_journey(doc.get("type")),
        "bookmark_status": "successfullyImplemented",
        "bookmark_user": "cicd",
        "mitre_technique": technique,
        "mitre_tactic": tactic,
        "killchain": killchain,
        "data_source_categories": data_source_categories,
        "search_name": search_name,
        "search": (doc.get("search") or "").strip(),
        "severity": severity,
        "alertvolume": "Very Low",  # safe default; tune per-detection later
        "displayapp": DISPLAYAPP,
        "channel": CHANNEL,
        "custom": "true",
        "highlight": "No",
        "howToImplement": (doc.get("how_to_implement") or "").strip(),
        "knownFP": (doc.get("known_false_positives") or "").strip(),
        "relevance": "",  # left empty; SSE shows the description there if blank
        "escu_cis": pipe_join(tags.get("cis20")),
        "escu_nist": pipe_join(tags.get("nist")),
        "escu_data_source": "AWS CloudTrail Logs" if "aws_cloudtrail" in (doc.get("data_source") or []) else "",
        "escu_providing_technologies": "AWS|Splunk",
    }

    return showcase


def main(argv: list[str]) -> int:
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    pattern = os.path.join(root, "detections", "**", "*.yml")

    rows = []
    failures = 0
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path, encoding="utf-8") as f:
                doc = yaml.safe_load(f)
        except Exception as e:
            sys.stderr.write(f"FAIL parse {path}: {e}\n")
            failures += 1
            continue

        if not isinstance(doc, dict):
            sys.stderr.write(f"FAIL not a dict {path}\n")
            failures += 1
            continue

        try:
            showcase = yaml_to_showcase(doc)
        except KeyError as e:
            sys.stderr.write(f"FAIL missing field {path}: {e}\n")
            failures += 1
            continue

        rows.append({"_key": doc["id"], "json": json.dumps(showcase, ensure_ascii=False)})
        sys.stderr.write(f"ok: {os.path.relpath(path, root)} -> {doc['id']}\n")

    if failures:
        sys.stderr.write(f"\n{failures} compile failures — aborting\n")
        return 1

    json.dump(rows, sys.stdout, indent=2)
    sys.stdout.write("\n")
    sys.stderr.write(f"\n{len(rows)} detections compiled\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
