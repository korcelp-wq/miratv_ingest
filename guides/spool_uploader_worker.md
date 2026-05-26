# MiraTV Spool Uploader Worker Guide

## Component: spool_uploader.ps1

### Purpose
Uploads spool files (event, telemetry, or governance signals) from the local ingest system to the server or designated endpoints. Ensures that all relevant signal data is transferred for aggregation, audit, and downstream processing.

### Location
`C:/miratv_ingest/spool_uploader.ps1`

### Operational Context
- **Domain:** Signal Spool / Data Upload
- **Trigger:** Manual, scheduled, or orchestrated by pipeline spine
- **Inputs:** Spool files (e.g., `igm_spool/`, `lake_spool/`, `ops_spool/`)
- **Outputs:** Uploaded data to server endpoints, status logs
- **Downstream:** Server-side aggregators, registry, or audit logs

### Usage Pattern
- Run periodically or after batch processing completes
- Can be invoked by orchestration scripts or as a standalone uploader
- Supports parameterized input (e.g., spool type, target endpoint)

### Key Steps
1. **Spool Discovery:** Identifies new or unuploaded spool files
2. **Upload:** Transfers files to server via HTTP POST or SCP
3. **Status Logging:** Records upload status and errors
4. **Cleanup:** Optionally archives or deletes successfully uploaded files

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/spool_uploader.ps1 -SpoolDir igm_spool/ -Endpoint https://miratv.club/_ingest/upload_spool.php
```

### Governance & Compliance
- All uploads are logged for traceability
- No direct database writes; uploads are append-only
- Follows fail-open policy for partial uploads

### CVI/Registry Metadata
- **process_name:** spool_uploader_worker
- **domain:** signal_spool
- **topic:** data_upload
- **unit_type:** worker

### Troubleshooting
- Check spool directory paths and permissions
- Review status logs for error details
- Ensure server endpoints are reachable

---
**Last updated:** 2026-02-02
