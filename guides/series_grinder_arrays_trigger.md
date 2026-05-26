# MiraTV Series Grinder Arrays Trigger Guide

## Component: 3_5_series_grinder_arrays_trigger.ps1

### Purpose
Triggers the series grinder pipeline for array-based series metadata extraction. Used to process and normalize series data that is structured as arrays, ensuring correct parsing and downstream compatibility.

### Location
`C:/miratv_ingest/triggers/3_5_series_grinder_arrays_trigger.ps1`

### Operational Context
- **Domain:** Trigger / Series Processing
- **Trigger:** Manual or orchestrated by batch pipeline
- **Inputs:** Array-structured series metadata files
- **Outputs:** Triggers grinder worker, logs status
- **Downstream:** Series grinder, normalization, and ingest workers

### Usage Pattern
- Run after raw series ingest, before enrichment
- Can be invoked directly or by orchestration scripts
- Supports parameterized input (e.g., input file)

### Key Steps
1. **Input Validation:** Checks for required array-structured files
2. **Trigger Grinder:** Invokes grinder worker with appropriate parameters
3. **Status Logging:** Logs trigger status and errors

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/triggers/3_5_series_grinder_arrays_trigger.ps1 -InputFile processed/series_array.json
```

### Governance & Compliance
- All trigger events are logged for traceability
- No direct database writes; only triggers downstream workers
- Follows fail-open policy for partial triggers

### CVI/Registry Metadata
- **process_name:** series_grinder_arrays_trigger
- **domain:** trigger
- **topic:** series_processing
- **unit_type:** trigger

### Troubleshooting
- Check input file paths and permissions
- Review logs for error details
- Ensure grinder worker is present and executable

---
**Last updated:** 2026-02-02
