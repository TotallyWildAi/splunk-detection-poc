# AI-assisted detection drafting

Runbook for the `ai-draft-detection` GitHub Actions workflow. Calls
Claude to draft a `detections/aws/<name>.yml` matching
`ai-workflow/SCHEMA.md`, then opens a **draft PR** so a human always
reviews before merge.

## 1. When to use this workflow

**Good fit:**
- New CVE / threat report / MITRE technique drops and you want quick
  first-pass coverage on a data source we already ingest (CloudTrail,
  VPC Flow Logs, GuardDuty).
- You can describe in one sentence what the detection should fire on,
  and have a rough idea which sourcetype it targets.

**Don't use it for:**
- Novel detection logic that needs heavy tuning — write it by hand.
- Techniques our data sources don't cover (e.g. on-prem AD). Claude
  will invent a sourcetype; the PR will look plausible and be wrong.
- "Translate this Sigma rule" — use a Sigma converter, not an LLM.

## 2. How to invoke

GitHub UI: **Actions → ai-draft-detection → Run workflow**. Inputs:

| Input | Required | Example |
|---|---|---|
| `technique` | yes | `T1078.004` |
| `name` | yes | `console-login-from-tor-exit-node` |
| `description` | yes | `Detects ConsoleLogin events from Tor exit IPs` |
| `source_url` | no | `https://example.com/report` |
| `model` | no | `claude-sonnet-4-6` (default) |

Press **Run workflow**. The `draft` job spins up; on success the step
summary prints the PR URL. The PR is opened **draft** on branch
`ai-draft/<technique>-<run_id>`.

## 3. Review checklist (expanded)

Walk this in order before clicking "Ready for review":

1. **SPL targets the right data source.** Confirm `search` uses a
   sourcetype we actually ingest (`taaws-config/config.yml`,
   `apps-src/`). Common failure: invents `pan_traffic`, `okta:auth`.
   Fix: rewrite the `index=… sourcetype=…` preamble to one of ours.
2. **ATT&CK technique ID is accurate.** Open the technique link in the
   PR body. Logic must match the technique's description, not a vaguely
   related one. Common failure: sub-technique drift (`T1078` vs
   `T1078.004`). Fix: edit `tags.mitre_attack`.
3. **`known_false_positives` is realistic for our environment.**
   Reference *our* FP sources (CI runner roles, on-call admins,
   automation), not generic "legitimate admin activity". Fix: rewrite in
   plain English, name actual systems.
4. **`how_to_implement` states real prereqs.** Must mention the
   relevant DMA (`Authentication`, `Network_Traffic`) and the TA-aws
   inputs that populate it. Common failure: "ensure TA-aws is
   installed" without naming the input stanza. Fix: name the SQS-based
   S3 input.
5. **Tests block has at least one sample-event reference.** Look for
   `tests.attack_data` with a `file:` pointing to a fixture. v1 doesn't
   execute these but the reference must exist so v2's runner has
   something to ingest. Fix: add a minimal fixture under
   `tests/attack_data/`.
6. **Run the SPL manually.** Paste `search` into Splunk web,
   "Last 24 hours", run. Plausible events? Zero results may be a true
   negative but the search must *parse*. Common failure: malformed
   `tstats` / wrong `datamodel=`. Fix: correct in YAML.

When all six tick, mark ready and merge. `splunk-config` deploys it.

## 4. Prompt-design rationale

- **Schema + exemplar in system prompt.** Cuts schema drift; without
  it Claude invents fields (`severity_label`) or omits required ones
  (`tags.mitre_attack`).
- **Available sourcetypes enumerated.** Stops hallucinated
  `pan_traffic` / `okta:auth`. Claude sticks to a given list far more
  reliably than to "use real sourcetypes".
- **Claude generates the UUID.** Keeps `id:` format consistent with
  hand-written detections (UUID v4); no post-processing.
- **`workflow_dispatch` only.** No auto-trigger on issues, comments,
  pushes. The value is the explicit "operator pressed the button"
  intent — auto-triggering would flood us with low-quality PRs.

## 5. Cost notes

Per draft: ~3K input tokens (schema + exemplar + sourcetypes + operator
input), ~800 output tokens. At Sonnet 4.6 pricing that's roughly
**$0.005 per draft**. Even at 10/day it's sub-$2/month. Skip
prompt-caching for v1.

## 6. Limitations of v1, roadmap to v2

- **v1 doesn't execute the SPL.** Reviewer runs it by hand. v2
  (Phase 6.1): Docker-Splunk runner ingests `tests.attack_data.file`
  fixtures, asserts on `asset_pass_criteria` — turns the PR into a
  green-tick "fires on bad, quiet on good" check.
- **v1 doesn't fetch `source_url`.** We pass the URL string only;
  Claude has training-data knowledge only. v2: WebFetch + summarize,
  inject summary into prompt.
- **v1 is AWS-only.** `--out` path hardcoded to `detections/aws/`. When
  we add a second data source, generalize or add `--out-dir`.

## 7. Adding a new data source / sourcetype

The drafter only knows sourcetypes listed in its system prompt:

1. Open `scripts/ai/draft-detection.py`.
2. Find `AVAILABLE_SOURCETYPES` (or the equivalent prompt section).
3. Add the sourcetype + CIM datamodel it accelerates
   (e.g. `aws:s3:accesslogs → Web`) matching the existing format.
4. If the DMA is new, add it to the `DATAMODELS` list too.
5. Commit, merge — next workflow run picks it up.
