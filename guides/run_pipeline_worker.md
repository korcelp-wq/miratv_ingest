# MiraTV Run Pipeline Worker Guide

## Component: run_pipeline.ps1

### Purpose
Orchestrates the full ingest pipeline for all content types (series, VOD, live) in the MiraTV system. Coordinates normalization, enrichment, embedding, and ingest stages for all data domains.

### Location
`C:/miratv_ingest/run_pipeline.ps1`

### Operational Context
- **Domain:** Pipeline Orchestration / Ingest
- **Trigger:** Manual or scheduled (e.g., nightly batch)
- **Inputs:** Raw and/or normalized content files (series, VOD, live)
- **Outputs:** Fully processed content data, logs, and status reports
- **Downstream:** Database ingest, reporting, and audit systems

### Usage Pattern
- Run after new data is available in `raw/` or `processed/`
- Can be invoked directly or by orchestration triggers
- Supports parameterized input (e.g., content type, stages to run)

### Key Steps
1. **Stage Coordination:** Invokes normalization, grinder, embedding, and ingest workers for all content types
2. **Error Handling:** Monitors for failures, logs errors, and may trigger retries
3. **Status Reporting:** Writes pipeline status and completion logs

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/run_pipeline.ps1 -ContentType all -Stages all
```

### Governance & Compliance
- All pipeline steps and errors are logged for traceability
- No direct database writes; only calls ingest endpoints or workers
- Follows fail-open policy for partial pipeline completion

### CVI/Registry Metadata
- **process_name:** run_pipeline_worker
- **domain:** pipeline_orchestration
- **topic:** ingest
- **unit_type:** orchestrator

### Troubleshooting
- Check logs for stage-specific errors
- Ensure all worker scripts are present and executable
- Review output directories for missing or partial data

---
**Last updated:** 2026-02-02
