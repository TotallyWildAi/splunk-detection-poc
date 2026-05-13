# Notes on Splunk Enterprise Security (ES) — what this POC has and doesn't

This POC runs **Splunk Enterprise** (the indexing/search/alerting platform) but
**not Splunk Enterprise Security (ES)** (the licensed SIEM application that runs
on top of it). ES requires a separate paid license and was deliberately
excluded to keep the POC cost-controlled.

Here's a precise accounting of what that means, so the demo story doesn't
oversell or undersell what's been built.

## What ES would add (NOT in this POC)

| ES capability | What it is | Closest workaround in this POC |
|---|---|---|
| **Notable Events framework** | ES's investigation-grade alert→ticket→assignment→status workflow. Detections fire into a structured queue with severity, owner, status, comments, audit log. | Detections fire plain Splunk alerts via email/webhook/script. We can simulate the visible part with a saved-search-driven dashboard backed by lookups, but the analyst workflow primitives aren't there. |
| **Risk-Based Alerting (RBA)** | The modern flagship detection paradigm. Each detection raises a *risk score* against a user/host/asset over time; a Notable only fires when accumulated risk crosses a threshold. Massively cuts false-positive volume. | Out of scope. Custom RBA-like aggregation can be hand-rolled with a `risk_index` summary index and a scheduled correlation search, but the Risk Analysis dashboard, asset/identity correlation, and decay logic don't exist without ES. |
| **Incident Review dashboard** | SOC-analyst-facing UI to triage, escalate, suppress, dispatch open Notables. | Splunk Security Essentials (SSE) ships some adjacent dashboards; we can build a custom one. Not equivalent. |
| **Asset & Identity framework** | Correlate events to known assets/identities (priority, category, owner, business unit) and reference those attributes inside detections. | A custom lookup table + KV store can stand in. Doesn't have ES's auto-merge / asset lifecycle behavior. |
| **Threat Intelligence framework** | Ingest IOC feeds (MISP, STIX/TAXII, OSINT, etc.) and auto-correlate against events. | Out of scope. ESCU detections that depend on the `threat_activity` datamodel won't fire correctly. |
| **Adaptive Response actions** | Pre-built playbook actions a detection can trigger (block IP at firewall, disable user, create ticket, run SOAR workflow). | Splunk Enterprise alert actions exist (email, webhook, script) — the surface is much narrower than ES's. |
| **Use-case dashboards** | Pre-built SOC dashboards (Access, Endpoint, Network, Threat Intelligence, etc.). | SSE has several adjacent dashboards. ESCU ships some too. Custom dashboards fill the gap. |
| **Correlation-search editor** | Structured UI for authoring detections that compile to scheduled saved-searches with all ES metadata. | We author detection content as YAML in `detections/`, lint+test in CI, deploy via Splunk REST API as scheduled saved-searches. Same outcome, no GUI editor. |

## What this POC HAS that's often confused with ES

| Capability | Source |
|---|---|
| **CIM data models** (Authentication, Network_Traffic, Endpoint, etc.) | `Splunk_SA_CIM` app — standalone, not part of ES. Foundation for DMA. |
| **Pre-built detection content** | `DA-ESS-ContentUpdate` (ESCU) app — ~1000+ detections published by Splunk's security team. Runs fine on Splunk Enterprise without ES; just doesn't get the Notable/RBA wrapper. |
| **Data Model Acceleration (DMA)** | Native Splunk Enterprise feature. Enabled per datamodel. |
| **Detection-content-as-code workflow** | Custom — built in this POC. Independent of whether the runtime is ES or vanilla Splunk. |
| **MITRE ATT&CK coverage browser** | Splunk Security Essentials (SSE) app — free. Has the coverage map dashboard that judges/reviewers love. |

## Capability-by-capability scoring (vs the 5 demo objectives)

| Demo objective | Status without ES |
|---|---|
| **1. Data parsing & ingestion** | ✅ Fully demonstrated. Splunk Enterprise + Splunk_TA_aws + `props.conf` / `transforms.conf` versioned in git. No ES dependency. |
| **2. Data Model Acceleration (DMA)** | ✅ Fully demonstrated. CIM datamodels + acceleration are core Splunk features. Show `tstats` vs raw-search benchmarks; show acceleration-health dashboard. |
| **3. Splunk detection engineering** | ✅ Detection logic + alert firing. ⚠️ Missing: the SOC-analyst experience (Notable triage, RBA risk timelines, asset enrichment). |
| **4. Detections as Code (CI/CD)** | ✅ Fully demonstrated. Detections versioned in YAML, validated in CI, deployed via Splunk REST API. Works identically against ES or vanilla Splunk at runtime. |
| **5. AI for detection development** | ✅ Fully demonstrated. AI workflow is entirely orthogonal to ES. |

## How to position this in a demo

If the interviewer/reviewer is familiar with Splunk's enterprise positioning,
they'll likely ask "and how does a fired detection become a Notable / get
assigned / get investigated?" — anticipate that.

Suggested framing:

> "I built this POC on Splunk Enterprise rather than ES to keep the
> license footprint manageable for a demo. The detection content I wrote is
> ES-compatible:
> - Every detection is **CIM-aligned** (uses `tstats` / `from datamodel`
>   against the same datamodels ES expects).
> - Each detection YAML has **annotations for MITRE ATT&CK** and
>   asset/identity correlation hooks.
> - The schema mirrors what `splunk/security_content` produces for direct
>   ESCU/ES ingestion.
>
> In an ES-licensed environment, these detections drop straight in as
> correlation searches, populate Notable Events, get an analyst owner, and
> can trigger RBA risk modifiers — without any rewrite."

That answer surfaces three things: you understand ES's role, the detections
you wrote are portable, you skipped the license for the demo (not because you
didn't know).

## Simulating ES-style Notable workflow (optional Phase 8)

Approximately 70% of the visible Notable experience can be hand-rolled:

- `index=alerts` (or `_audit`) as a destination for detection-fire events
- Lookup table for assigning severity, owner, status to each rule
- KV-store-backed comment thread / triage history
- A custom dashboard listing open "notables" with bulk actions

This is mainly cosmetic — useful if the demo audience expects a SOC-analyst UI
in the screenshots. If we add it, it'll live as Phase 8 in the repo.
