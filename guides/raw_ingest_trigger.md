# MiraTV Raw Ingest Trigger Guide

## Component: 4raw_ingest_trigger.ps1

### Purpose
Triggers the raw ingest pipeline for new content from providers. Used to initiate the download and staging of raw data (series, VOD, live) into the ingest system.

### Location
`C:/miratv_ingest/triggers/4raw_ingest_trigger.ps1`

### Operational Context
- **Domain:** Pipeline Trigger / Raw Ingest
- **Trigger:** Manual or orchestrated by batch scripts or spine
- **Inputs:** Provider configuration, target content type
- **Outputs:** Raw data files in `raw/`, logs status
- **Downstream:** Normalization, grinder, enrichment workers

### Usage Pattern
- Run to ingest new data from a provider
- Supports parameterized input (e.g., provider, content type)

### Key Steps
1. **Input Validation:** Checks provider config and parameters
2. **Triggering:** Initiates download/staging of raw data
3. **Status Logging:** Records trigger status and errors

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/triggers/4raw_ingest_trigger.ps1 -Provider xtream -ContentType series
```

### Governance & Compliance
- All trigger events are logged for traceability
- No direct database writes; only triggers downstream workers
- Follows fail-open policy for partial ingest

### CVI/Registry Metadata
- **process_name:** raw_ingest_trigger
- **domain:** pipeline_trigger
- **topic:** raw_ingest
- **unit_type:** trigger

### Troubleshooting
- Check provider config and permissions
- Review logs for error details
- Ensure downstream workers are present and executable

---
**Last updated:** 2026-02-02
