# MiraTV Run Series Pipeline Worker Guide

## Component: run_series_pipeline.ps1

### Purpose
Orchestrates the full series processing pipeline, coordinating normalization, enrichment, embedding, and ingest stages for series content. Acts as a master script to ensure all required steps are executed in sequence.

### Location
`C:/miratv_ingest/run_series_pipeline.ps1`

### Operational Context
- **Domain:** Pipeline Orchestration / Series Processing
- **Trigger:** Manual or scheduled (e.g., nightly batch)
- **Inputs:** Raw and/or normalized series files
- **Outputs:** Fully processed series data, logs, and status reports
- **Downstream:** Database ingest, reporting, and audit systems

### Usage Pattern
- Run after new series data is available in `raw/` or `processed/`
- Can be invoked directly or by orchestration triggers
- Supports parameterized input (e.g., target series, stages to run)

### Key Steps
1. **Stage Coordination:** Invokes normalization, grinder, embedding, and ingest workers in order
2. **Error Handling:** Monitors for failures, logs errors, and may trigger retries
3. **Status Reporting:** Writes pipeline status and completion logs

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/run_series_pipeline.ps1 -SeriesId 42 -Stages all
```

### Governance & Compliance
- All pipeline steps and errors are logged for traceability
- No direct database writes; only calls ingest endpoints or workers
- Follows fail-open policy for partial pipeline completion

### CVI/Registry Metadata
- **process_name:** run_series_pipeline_worker
- **domain:** pipeline_orchestration
- **topic:** series_processing
- **unit_type:** orchestrator

### Troubleshooting
- Check logs for stage-specific errors
- Ensure all worker scripts are present and executable
- Review output directories for missing or partial data

---
**Last updated:** 2026-02-02
