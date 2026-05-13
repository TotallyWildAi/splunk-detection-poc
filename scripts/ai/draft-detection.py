#!/usr/bin/env python3
"""
draft-detection.py — AI-drafter for Splunk detection YAMLs.

Takes a MITRE technique ID and a few descriptors, calls the Claude API,
and emits a schema-conformant detection YAML (see detections/SCHEMA.md).

Part of Phase 6 of the splunk-detection-poc. Designed to be invoked
either by a human or by the Phase 6 GitHub Actions workflow.

Usage:
    python scripts/ai/draft-detection.py \\
        --technique T1078.004 \\
        --name console-login-from-tor-exit-node \\
        [--source-url https://attack.mitre.org/techniques/T1078/004/] \\
        [--description "Detects CloudTrail ConsoleLogin events from Tor exit IPs"] \\
        [--out detections/aws/console-login-from-tor-exit-node.yml] \\
        [--model claude-sonnet-4-6]

Env:
    ANTHROPIC_API_KEY   required.

Exit codes:
    0   success — YAML written to --out (or stdout).
    1   bad args / missing files / missing API key.
    2   Claude returned something we can't validate, even after one retry.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import os
import re
import sys
import uuid
from pathlib import Path
from typing import Tuple

import yaml

try:
    import anthropic
except ImportError:  # pragma: no cover
    sys.stderr.write(
        "error: anthropic SDK not installed. Run: pip install anthropic pyyaml\n"
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Repo root — the script lives at <repo>/scripts/ai/draft-detection.py
REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "detections" / "SCHEMA.md"
EXEMPLAR_PATH = REPO_ROOT / "detections" / "aws" / "cloudtrail-disabled.yml"

# Required top-level keys per detections/SCHEMA.md
REQUIRED_FIELDS = (
    "id",
    "name",
    "version",
    "author",
    "date",
    "description",
    "type",
    "data_source",
    "search",
    "tags",
)

# Model. claude-sonnet-4-6 is fast, cheap, structured-output reliable.
DEFAULT_MODEL = "claude-sonnet-4-6"

SYSTEM_PROMPT = (
    "You are a senior Splunk detection engineer authoring CIM-aligned, "
    "ES-compatible detection content for AWS CloudTrail + VPC Flow Logs data."
)


# ---------------------------------------------------------------------------
# Prompt assembly
# ---------------------------------------------------------------------------

def build_user_prompt(
    *,
    schema_md: str,
    exemplar_yaml: str,
    technique: str,
    name: str,
    description: str | None,
    source_url: str | None,
    detection_id: str,
    today_iso: str,
    extra_feedback: str | None = None,
) -> str:
    """Compose the user-turn prompt for Claude.

    Order of sections matters: schema first (spec), then exemplar (concrete
    pattern), then hard constraints, then the actual request, then the
    output contract. This keeps the model anchored on schema compliance
    before it starts inventing SPL.
    """

    request_block_lines = [
        f"- MITRE technique: {technique}",
        f"- Detection name (kebab-case, also use as Splunk saved-search name in Title Case): {name}",
    ]
    if description:
        request_block_lines.append(f"- Author-provided description / intent: {description}")
    if source_url:
        request_block_lines.append(f"- Reference URL to include in `references`: {source_url}")
    request_block = "\n".join(request_block_lines)

    feedback_block = ""
    if extra_feedback:
        feedback_block = (
            "\n## Previous attempt failed validation\n\n"
            "Your previous response failed validation with this error:\n\n"
            f"```\n{extra_feedback}\n```\n\n"
            "Fix the issue and respond again following ALL the rules below.\n"
        )

    return f"""# Task

Author a single Splunk detection YAML that conforms exactly to the schema
below. The detection should cover MITRE ATT&CK technique `{technique}`.

{feedback_block}
## Schema (detections/SCHEMA.md)

The YAML you produce MUST validate against this schema. Every required
field must be present and correctly typed.

````markdown
{schema_md}
````

## Exemplar (detections/aws/cloudtrail-disabled.yml)

Follow this structure EXACTLY — same field order, same YAML style (block
scalars with `>-` for multi-line strings, two-space indentation, ISO-format
quoted date). This is a high-quality reference; mirror its shape.

````yaml
{exemplar_yaml}
````

## Hard constraints on the data shape

These reflect the actual lab environment. Do NOT invent fields or sources
outside this list.

- Available indexes: `index=main`
- Available sourcetypes:
  - `aws:cloudtrail`
  - `aws:cloudwatchlogs:vpcflow`
- Available CIM datamodels (accelerated and queryable via tstats):
  - `Change`
  - `Authentication`
  - `Network_Traffic`
- SPL style:
  - PREFER `| tstats summariesonly=t count from datamodel=<DM> where ... by ...`
    when the fields you need are covered by CIM. This is the fast path.
  - FALL BACK to raw `search index=main sourcetype=aws:cloudtrail eventName=...`
    only when the field you need is not in CIM (e.g.
    `responseElements.ConsoleLogin`, `additionalEventData.MFAUsed`,
    `requestParameters.cidrIp`, `userIdentity.sessionContext.*`).
  - State the CIM-vs-raw rationale in `how_to_implement`.
  - Do NOT use private macros like `` `drop_dm_object_name` `` unless they
    appear in the exemplar above — keep SPL portable across environments.
  - Do NOT bake time-bounds into the SPL; the compiler injects
    `dispatch.earliest_time` / `dispatch.latest_time` at deploy time.
  - End every search with a `stats`/`tstats ... by` projection that yields
    the dimensions an analyst needs (user, src, resource, count) — no
    `| table *`.

## Detection request

{request_block}

## Output contract

- Today's date is `{today_iso}`. Use this as the value of the `date` field
  (quoted as a string: `'{today_iso}'`).
- Use `{detection_id}` as the value of the `id` field. Do not generate a
  different UUID.
- `author` must be `TotallyWildAi`.
- `version` must be `1`.
- `tags.mitre_attack_id` must contain `{technique}` (and may contain other
  accurate sub-techniques, but do NOT copy the exemplar's `T1562.008` if
  it's not appropriate).
- Respond with ONLY a YAML document. No prose before or after. No code
  fences. No commentary. The first byte of your response must be the first
  byte of the YAML.
"""


# ---------------------------------------------------------------------------
# Claude call + response parsing
# ---------------------------------------------------------------------------

CODE_FENCE_RE = re.compile(
    r"^\s*```(?:[a-zA-Z0-9_-]*)?\s*\n(.*?)\n```\s*$",
    re.DOTALL,
)


def strip_code_fences(text: str) -> str:
    """If Claude wrapped its answer in ``` fences, peel them off.

    Claude is told not to do this, but tends to anyway ~10% of the time.
    """
    text = text.strip()
    m = CODE_FENCE_RE.match(text)
    if m:
        return m.group(1).strip()
    # Also handle the case where fences exist but there's leading prose.
    if "```" in text:
        # Take the first fenced block.
        parts = text.split("```")
        if len(parts) >= 3:
            # parts[1] starts with optional lang tag + newline
            inner = parts[1]
            if "\n" in inner:
                first_line, rest = inner.split("\n", 1)
                # If first_line looks like a lang tag (no spaces, short), drop it
                if re.fullmatch(r"[a-zA-Z0-9_-]{0,16}", first_line.strip()):
                    return rest.strip()
            return inner.strip()
    return text


def call_claude(
    client: anthropic.Anthropic,
    *,
    model: str,
    user_prompt: str,
) -> str:
    """Single API call. Returns the assistant's text response."""
    resp = client.messages.create(
        model=model,
        max_tokens=2000,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_prompt}],
    )
    # Concatenate any text blocks defensively (typically just one).
    parts: list[str] = []
    for block in resp.content:
        if getattr(block, "type", None) == "text":
            parts.append(block.text)
    return "".join(parts)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_yaml(raw: str) -> Tuple[dict | None, str | None]:
    """Parse + shape-check the YAML.

    Returns (parsed_dict, None) on success, or (None, error_message).
    """
    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        return None, f"YAML parse error: {exc}"

    if not isinstance(doc, dict):
        return None, (
            f"top-level YAML must be a mapping/dict, got {type(doc).__name__}"
        )

    missing = [f for f in REQUIRED_FIELDS if f not in doc]
    if missing:
        return None, (
            f"missing required top-level fields: {missing}. "
            f"Schema requires: {list(REQUIRED_FIELDS)}."
        )

    # Light-touch type sanity on a few fields. We don't deep-validate tags
    # here — the compiler in Phase 5 does that.
    if not isinstance(doc["data_source"], list) or not doc["data_source"]:
        return None, "`data_source` must be a non-empty list of strings"
    if not isinstance(doc["tags"], dict):
        return None, "`tags` must be a mapping"
    if not isinstance(doc["search"], str) or not doc["search"].strip():
        return None, "`search` must be a non-empty string"

    return doc, None


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Draft a Splunk detection YAML from a MITRE technique ID using Claude.",
    )
    p.add_argument("--technique", required=True, help="MITRE ATT&CK technique ID, e.g. T1078.004")
    p.add_argument(
        "--name",
        required=True,
        help="Kebab-case detection slug, e.g. console-login-from-tor-exit-node",
    )
    p.add_argument("--source-url", default=None, help="Reference URL to embed in `references`.")
    p.add_argument("--description", default=None, help="Author-provided intent / scope hint.")
    p.add_argument(
        "--out",
        default=None,
        help="Path to write the generated YAML. If omitted, writes to stdout.",
    )
    p.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Anthropic model id (default: {DEFAULT_MODEL}).",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        sys.stderr.write("error: ANTHROPIC_API_KEY env var is not set.\n")
        return 1

    if not SCHEMA_PATH.is_file():
        sys.stderr.write(f"error: schema not found at {SCHEMA_PATH}\n")
        return 1
    if not EXEMPLAR_PATH.is_file():
        sys.stderr.write(f"error: exemplar not found at {EXEMPLAR_PATH}\n")
        return 1

    schema_md = SCHEMA_PATH.read_text(encoding="utf-8")
    exemplar_yaml = EXEMPLAR_PATH.read_text(encoding="utf-8")

    detection_id = str(uuid.uuid4())
    today_iso = _dt.date.today().isoformat()

    user_prompt = build_user_prompt(
        schema_md=schema_md,
        exemplar_yaml=exemplar_yaml,
        technique=args.technique,
        name=args.name,
        description=args.description,
        source_url=args.source_url,
        detection_id=detection_id,
        today_iso=today_iso,
    )

    client = anthropic.Anthropic(api_key=api_key)

    sys.stderr.write(
        f"[draft-detection] model={args.model} technique={args.technique} "
        f"name={args.name} id={detection_id}\n"
    )

    # Attempt 1
    raw = call_claude(client, model=args.model, user_prompt=user_prompt)
    candidate = strip_code_fences(raw)
    parsed, err = validate_yaml(candidate)

    if err is not None:
        sys.stderr.write(
            f"[draft-detection] first attempt failed validation: {err}\n"
            "[draft-detection] retrying once with feedback...\n"
        )
        retry_prompt = build_user_prompt(
            schema_md=schema_md,
            exemplar_yaml=exemplar_yaml,
            technique=args.technique,
            name=args.name,
            description=args.description,
            source_url=args.source_url,
            detection_id=detection_id,
            today_iso=today_iso,
            extra_feedback=err,
        )
        raw = call_claude(client, model=args.model, user_prompt=retry_prompt)
        candidate = strip_code_fences(raw)
        parsed, err = validate_yaml(candidate)
        if err is not None:
            sys.stderr.write(
                f"[draft-detection] retry also failed: {err}\n"
                "[draft-detection] raw response was:\n"
                "---8<---\n"
                f"{raw}\n"
                "--->8---\n"
            )
            return 2

    # Force our pre-generated id into the output even if Claude ignored
    # instructions and emitted a different one — we control identity.
    if parsed.get("id") != detection_id:
        sys.stderr.write(
            f"[draft-detection] warning: Claude emitted id={parsed.get('id')!r}, "
            f"overwriting with {detection_id}\n"
        )
        parsed["id"] = detection_id
        # Re-serialise from the parsed dict to keep id authoritative.
        candidate = yaml.safe_dump(
            parsed,
            sort_keys=False,
            allow_unicode=True,
            default_flow_style=False,
            width=100,
        )

    if args.out:
        out_path = Path(args.out)
        if not out_path.is_absolute():
            out_path = REPO_ROOT / out_path
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(candidate.rstrip() + "\n", encoding="utf-8")
        sys.stderr.write(f"[draft-detection] wrote {out_path}\n")
    else:
        sys.stdout.write(candidate.rstrip() + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
