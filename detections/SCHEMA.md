# Detection YAML schema

Detections in this repo are authored as YAML files (one detection per file,
kebab-case filename) under `detections/<source>/` where `<source>` is the
primary data-source family (e.g. `aws/`, `okta/`, `endpoint/`).

The schema is modelled after [`splunk/security_content`](https://github.com/splunk/security_content/tree/develop/detections)
and intentionally trimmed for this POC. The CI compiler in Phase 5 reads
these YAMLs and renders each one into a Splunk REST API payload (POST
`/services/saved/searches`) — so every field below has to either map to a
saved-search property or feed metadata the compiler emits as macro/comment
preamble in the search string.

## Top-level fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string (UUID v4) | yes | Stable identity. Generated once per detection at creation time and never changed. Used as the detection's primary key in deploy reconciliation. |
| `name` | string | yes | Short human title. Becomes the saved-search name (Splunk's `name` REST param). |
| `version` | int | yes | Starts at 1, bumped on any change to `search`, `tags`, or detection semantics. Renames don't bump. |
| `author` | string | yes | `TotallyWildAi` for content in this repo. |
| `date` | string (YYYY-MM-DD) | yes | Creation date — not last-modified. Use git for history. |
| `description` | string | yes | 2–3 sentences: what it detects + why it matters. Rendered into the Splunk saved-search description. |
| `type` | enum | yes | One of `TTP`, `Anomaly`, `Hunting`. TTP = known adversary technique with high-fidelity match; Anomaly = statistical/rate-based; Hunting = low-fidelity, analyst-driven, not for production alerting. |
| `data_source` | list[string] | yes | Identifiers from a controlled vocabulary: `aws_cloudtrail`, `aws_vpc_flow`, `aws_guardduty`, `okta`, `hec_synthetic`, etc. |
| `search` | string (SPL) | yes | The full SPL. See conventions below. |
| `how_to_implement` | string | yes | 1–2 sentences on prerequisites (TA installed, datamodel accelerated, lookup populated, etc.). |
| `known_false_positives` | string | yes | Common FPs + tuning hints. Plain text. |
| `references` | list[string] | yes | URLs — Splunk security_content equivalent, AWS docs, MITRE technique pages, blog writeups. |
| `tags` | object | yes | See below. |
| `tests` | list[object] | yes | See below. May be empty `[]` for hunting content with no canned sample. |

## `tags` object

| Field | Type | Required | Notes |
|---|---|---|---|
| `analytic_story` | list[string] | yes | One or more campaign/story labels (e.g. `AWS Identity & Access Management`, `AWS Defense Evasion`). Loose taxonomy — mirrors security_content stories. |
| `asset_type` | string | yes | What's being attacked. e.g. `AWS Account`, `AWS S3 Bucket`, `EC2 Instance`, `IAM User`. |
| `confidence` | int (0–100) | yes | How confident a positive hit indicates real malicious activity. ~30 for hunting, ~70 for tunable TTP, ~90 for unambiguous. |
| `impact` | int (0–100) | yes | Severity if confirmed true positive. Multiplied with `confidence` by ES to derive RBA risk score. |
| `mitre_attack_id` | list[string] | yes | T-codes incl. sub-techniques (e.g. `T1078.004`). Accurate, not aspirational. |
| `kill_chain_phases` | list[string] | yes | Lockheed Martin phases: `Reconnaissance`, `Weaponization`, `Delivery`, `Exploitation`, `Installation`, `Command and Control`, `Actions on Objectives`. ATT&CK tactic names (`Persistence`, `Privilege Escalation`, etc.) are also accepted by the compiler. |
| `cis20` | list[string] | optional | CIS Controls v8 ids (e.g. `CIS 6`). |
| `nist` | list[string] | optional | NIST CSF function categories (e.g. `DE.CM`, `PR.AC`). |

## `tests` list

Each test entry:

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Short test description, e.g. `cloudtrail StopLogging on management trail`. |
| `attack_data` | list[object] | yes | One or more sample events to ingest before running the search. Each entry: `{file, sourcetype, source}`. `file` is a path relative to `demo-data/` containing a JSON event or `.json.gz` CloudTrail file. `sourcetype` and `source` are the values to assign at ingest. |
| `asset_pass_criteria` | string | yes | Plain-language pass criteria, e.g. `search returns >=1 event with userIdentity.userName=admin`. The Phase 5 test runner translates this into an assertion. |

Tests are executed in CI against an ephemeral Docker Splunk:

1. Spin up `splunk/splunk:10.2` container with HEC enabled
2. For each `attack_data` entry, POST the sample event to HEC with the
   declared `sourcetype` / `source`
3. Wait for indexing + (for DMA-backed detections) acceleration build
4. Run the detection's `search` with `earliest=-1h latest=now`
5. Assert against `asset_pass_criteria`

## SPL conventions

- **Prefer accelerated datamodels.** Use `| tstats summariesonly=t count from datamodel=<DM> where ... by ...` for any fields covered by CIM Change or Authentication. Acceleration makes these run in milliseconds.
- **Fall back to raw search** for fields not in CIM (e.g. `responseElements.ConsoleLogin`, `requestParameters.cidrIp`, `additionalEventData.MFAUsed`). Use `search index=main sourcetype=aws:cloudtrail eventName=...` and rely on indexed-extracted JSON fields from `Splunk_TA_aws`.
- **Time bounds belong in the schedule**, not the SPL. The compiler injects `earliest=-5m@m latest=now` (or whatever the schedule dictates) at deploy time. Authors write SPL assuming a 5-minute window unless a longer lookback is necessary, in which case the rationale goes in `how_to_implement`.
- **Always project a `stats` (or `tstats`-`by`) at the end** so the alert payload contains the dimensions an analyst needs (user, IP, resource, count). Avoid `| table *` — too noisy.
- **No leading `| sort` over wide datasets.** Stats first, sort last, sort on the aggregated result.
- **Target <30s execution.** Detections are scheduled searches; >30s indicates a missing accelerator or an over-broad lookback.

## Compiler / deploy mapping

The Phase 5 compiler reads each YAML and POSTs to `/services/saved/searches` with:

| Splunk REST param | YAML source |
|---|---|
| `name` | `name` |
| `search` | `search` (with time-range injected via `dispatch.earliest_time` / `dispatch.latest_time`) |
| `description` | `description` |
| `cron_schedule` | derived per detection `type` (TTP: `*/5 * * * *`, Anomaly: `*/15 * * * *`, Hunting: not scheduled) |
| `dispatch.earliest_time` | `-5m@m` (TTP) or `-15m@m` (Anomaly) |
| `dispatch.latest_time` | `now` |
| `is_scheduled` | `1` for TTP/Anomaly, `0` for Hunting |
| `alert.severity` | mapped from `tags.impact` (>=80 → high, >=50 → medium, else low) |
| `action.email`, `action.webhook` | from `alerts.conf` defaults in the target Splunk install |

ATT&CK ids, kill-chain phases, story, confidence, impact, and the detection
`id` are emitted as `comment` preamble in the SPL itself so they survive a
Splunk-side export and are visible in Search Inspector — ES picks the same
metadata out of macro comments when ESCU content is ingested.

## Filename + path

- Path: `detections/<source>/<kebab-case-name>.yml`
- Filename mirrors `name` lowercased and kebab-cased; small drift is fine,
  the `id` is what reconciliation keys on.
- One detection per file.
