# MiraTV Spool Uploader Utility Guide

## Component: upload_spool_once.ps1

### Purpose
Performs a one-time upload of a specified spool file (event, telemetry, or governance signal) to the server or designated endpoint. Used for ad-hoc or manual uploads outside of scheduled or batch processes.

### Location
`C:/miratv_ingest/upload_spool_once.ps1`

### Operational Context
- **Domain:** Signal Spool / Data Upload
- **Trigger:** Manual, ad-hoc
- **Inputs:** Single spool file (e.g., from `igm_spool/`, `lake_spool/`, `ops_spool/`)
- **Outputs:** Uploaded data to server endpoint, status log
- **Downstream:** Server-side aggregators, registry, or audit logs

### Usage Pattern
- Run manually for a specific file needing upload
- Supports parameterized input (e.g., file path, target endpoint)

### Key Steps
1. **Input Validation:** Checks that the specified file exists and is readable
2. **Upload:** Transfers the file to the server via HTTP POST or SCP
3. **Status Logging:** Records upload status and errors

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/upload_spool_once.ps1 -File igm_spool/event_20260202.log -Endpoint https://miratv.club/_ingest/upload_spool.php
```

### Governance & Compliance
- All uploads are logged for traceability
- No direct database writes; uploads are append-only
- Follows fail-open policy for partial uploads

### CVI/Registry Metadata
- **process_name:** upload_spool_once_utility
- **domain:** signal_spool
- **topic:** data_upload
- **unit_type:** utility

### Troubleshooting
- Check file path and permissions
- Review status log for error details
- Ensure server endpoint is reachable

---
**Last updated:** 2026-02-02
