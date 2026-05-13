# `draft-detection.py` prompt template

This document is the **source-controlled record** of the prompt
`scripts/ai/draft-detection.py` sends to Claude when drafting a new
detection YAML. The runtime source-of-truth is the
`build_user_prompt(...)` function in the Python script — if the two
diverge, the Python wins. Keep this doc updated when you change the
prompt logic in the script.

## Inputs interpolated into the prompt

| Placeholder | Value at runtime |
|---|---|
| `{schema_md}` | Verbatim contents of `detections/SCHEMA.md`. |
| `{exemplar_yaml}` | Verbatim contents of `detections/aws/cloudtrail-disabled.yml`. |
| `{technique}` | CLI `--technique`, e.g. `T1078.004`. |
| `{name}` | CLI `--name`, kebab-case slug. |
| `{description}` | CLI `--description` (optional). |
| `{source_url}` | CLI `--source-url` (optional). |
| `{detection_id}` | A fresh `uuid.uuid4()` generated in Python. The script overrides Claude's `id` field with this value post-parse. |
| `{today_iso}` | `datetime.date.today().isoformat()` — used for the `date` field. |
| `{feedback_block}` | Empty on the first attempt; on retry, contains the YAML/validation error from the first attempt. |

## System prompt

```
You are a senior Splunk detection engineer authoring CIM-aligned,
ES-compatible detection content for AWS CloudTrail + VPC Flow Logs data.
```

## User prompt structure

The user-turn message is composed of six sections, in this order:

1. **Task line** — single sentence stating: produce a YAML detection for
   technique `{technique}`.
2. **Feedback block** (retries only) — the validation error from the
   previous attempt, asking for a fix.
3. **Schema** — the entire `detections/SCHEMA.md` embedded in a fenced
   markdown block.
4. **Exemplar** — `detections/aws/cloudtrail-disabled.yml` embedded in a
   fenced YAML block, framed as "follow this structure EXACTLY".
5. **Hard constraints on the data shape** — bulleted list:
   - Available indexes: `index=main`
   - Available sourcetypes: `aws:cloudtrail`,
     `aws:cloudwatchlogs:vpcflow`
   - Available CIM datamodels (accelerated): `Change`, `Authentication`,
     `Network_Traffic`
   - Prefer `| tstats summariesonly=t count from datamodel=<DM> where ...
     by ...` when CIM covers the fields.
   - Fall back to raw `search index=main sourcetype=...` only when CIM
     doesn't cover the needed fields. Rationale goes in `how_to_implement`.
   - Don't invent sourcetypes.
   - Don't use private macros like `` `drop_dm_object_name` `` unless
     they appear in the exemplar.
   - Don't bake time bounds into the SPL — compiler injects them.
   - End every search with a `stats` / `tstats ... by` projection.
6. **Detection request** — bullets for `--technique`, `--name`,
   `--description`, `--source-url`.
7. **Output contract** — five non-negotiables:
   - Use `{today_iso}` for `date`.
   - Use `{detection_id}` for `id`.
   - `author` = `TotallyWildAi`.
   - `version` = `1`.
   - `tags.mitre_attack_id` must contain `{technique}` and must NOT copy
     the exemplar's technique IDs unless appropriate.
   - Respond with ONLY a YAML document — no prose, no code fences, no
     commentary. First byte = first byte of YAML.

## Design rationale / judgment calls

- **Schema before exemplar.** The schema is the spec; the exemplar is one
  legal instance. Putting the schema first reduces the chance Claude
  pattern-matches on the exemplar's exact ATT&CK technique
  (`T1562.008`) and copies it.
- **Embed both files verbatim.** Cheaper than describing the schema in
  prose. Claude is very good at conforming when shown an exact gold
  reference plus the spec it was derived from.
- **One exemplar, not multiple.** Two exemplars (CIM + raw) tripled token
  count without measurable quality gain in pilot runs; the spec already
  describes the raw-search fallback rule, and Claude infers correctly
  from one example plus the rule. The `console-login-without-mfa.yml`
  raw-SPL pattern is referenced in the schema text itself.
- **UUID generated client-side.** Claude is asked to use a specific
  pre-generated `id`, AND the Python script post-processes the parsed
  YAML to overwrite `id` with the script-generated UUID. Identity must
  not be model-dependent — re-running the script with the same args must
  produce a different detection identity, and the upstream Phase 5
  reconciliation keys on `id`.
- **Date passed in.** Same reason — deterministic, no risk of Claude
  guessing a stale or future date.
- **`max_tokens=2000`.** Empirically ~1.2-1.5k for a full detection
  including tests; 2000 is a safe ceiling under the doc-budget for a
  single tool turn.
- **One retry with the validator's error.** If the first attempt has a
  shape problem (missing field, bad YAML, wrong type), re-prompt with
  the exact error text appended. Two-shot recovery in pilot was ~95%
  successful for typical mistakes (missing `cis20` was the most common,
  followed by `tests: []` emitted as a string).
- **Strip code fences defensively.** The output contract forbids fences,
  but Claude reverts ~10% of the time. `strip_code_fences` peels them
  off without complaining.
- **No prompt caching for v1.** The schema + exemplar block is ~3.5kB
  and the script is run interactively or once-per-CI-run, so caching
  isn't worth the API complexity yet. Revisit if Phase 6 grows a batch
  mode.

## Known limitations of v1

- No semantic validation of the SPL — we parse YAML shape, but a
  syntactically valid YAML with bogus SPL would slip through. The Phase 5
  test runner catches this when it tries to dispatch the search.
- No taxonomy enforcement on `data_source`, `analytic_story`,
  `kill_chain_phases`. Schema lists them as a "controlled vocabulary" but
  the Python script trusts Claude.
- The script only mentions AWS CloudTrail and VPC Flow data; if someone
  asks for an Okta or GuardDuty detection, the prompt will silently
  steer Claude toward AWS-shaped output. Broaden the "available
  sourcetypes" section when those data sources come online.
- Re-running with the same `--name` produces a NEW `id` and overwrites
  the file. There's no "update in place, bump version" mode — that's a
  Phase 6.1 feature.
