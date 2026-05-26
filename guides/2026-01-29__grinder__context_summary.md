<!--
COPILOT INSTRUCTIONS (READ CAREFULLY):

You are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.

DO:
- Describe intent, pressure, goals, blind spots
- Use plain language
- Leave unknowns explicit

DO NOT:
- Propose solutions
- Invent metrics
- Write code
- Make decisions
- Use theory language

This file is a SITUATIONAL SNAPSHOT, not a design doc.

Component: Grinder / Ingest Pipeline
-->

# Contextual Summary — Grinder / Ingest Pipeline

## Component Role

Local batch processor on `C:\miratv_ingest\`. Reads raw IPTV provider data (JSON/XML). Normalizes into structured JSON. Queues for database ingest. Produces processed files and quarantine logs for failures.

## Current Intent

Extract structured data from unreliable provider feeds without inventing missing fields. Preserve partial truth explicitly. Flag ambiguities and failures for human review. Enable downstream database ingest with confidence.

## Operating Mode

Batch-oriented workers (C:\miratv_ingest\workers\). Read raw/ folder. Parse JSON/XML. Extract fields into normalized payloads. Quarantine failures into dedicated directories. Write processed/ outputs. Mark checkpoint files for orchestrator tracking.

## Frequency & Cadence

Triggered by PowerShell orchestration (spine scheduler). Currently manual or scheduled nightly. No real-time processing. Single provider at a time or sequential batch runs.

## Pressures Detected

Provider data inconsistent (missing fields, renamed keys). Parser failures block entire batches. No graceful degradation for partial data. Manual quarantine review creates bottleneck. Unknown which failures are recoverable vs. genuine data issues.

## Active Constraints

Local filesystem only (no direct DB writes). Must preserve all raw data for audit. Parser logic coupled to specific provider format. Quarantined files accumulate without automated cleanup or re-processing. No real-time feedback from database ingest layer.

## Short-Horizon Goals (Now → Soon)

Parse more provider formats without code changes. Reduce quarantine pile. Surface grinder failures to governance system. Enable AI-assisted recovery of quarantined records. Track parse success rate per provider.

## Long-Horizon Goals

Zero manual quarantine intervention. Self-healing grinder that learns provider patterns. AI suggests format fixes. Streaming (not batch) processing. Real-time feedback loop from database → grinder.

## Blind Spots

Unclear which quarantined files are fixable vs. permanently malformed. No visibility into downstream ingest failures (grinder succeeded, DB write failed). Unknown provider field semantics (is this field optional or missing due to provider error?). No cross-provider pattern recognition.

## Friction Points

Grinder workers run independently; no coordination with other workers. Quarantined files require manual inspection. No integration with governance rules (what should grinder reject vs. accept?). Errors don't trigger escalation; they just accumulate in logs.

## Metrics Currently Used

File count (raw, processed, quarantine). Parse success/failure count. Job duration.

## Metrics Missing

Per-field extraction confidence. Provider consistency score. Quarantine resolution rate. Downstream ingest success vs. grinder output quality. Time-to-fix for quarantined records.

## Suggested Stored Procedures (Do Not Exist Yet)

- `sp_grinder_register_job()` - log start/end of grinder run
- `sp_grinder_log_failure()` - insert quarantine event with provider, file, error reason
- `sp_grinder_get_recoverable_failures()` - query quarantine for retryable patterns
- `sp_grinder_confidence_score()` - return extraction confidence per field per provider

## Desired Context From Other Components

Governance: Which fields are mandatory vs. optional? Ops: What downstream DB failures occurred from grinder output? Lake: Historical provider format patterns (has this field appeared before?). Inhibitor: Rules about what constitutes acceptable partial data.

## Confidence Level

High on current state (observable filesystem, checkpoint files). Medium on downstream effects (unknown how DB layer sees grinder failures). Low on provider semantics (unclear if missing fields are errors or valid nulls).

## Notes

Grinder is effectively a filter and normalizer, not an enforcer. It passes data downstream; database layer decides accept/reject. This separation is intentional but creates blind spot: grinder doesn't know if its output is usable.

