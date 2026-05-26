# MiraTV Series Normalize Worker Guide

## Component: series_normalize.ps1

### Purpose
Normalizes raw series metadata into a structured, consistent format for downstream processing and ingestion. Handles field mapping, data cleaning, and schema alignment for series content.

### Location
`C:/miratv_ingest/_workers/series_normalize.ps1`

### Operational Context
- **Domain:** Content Normalization / Series Processing
- **Trigger:** Manual, scheduled, or orchestrated by pipeline spine
- **Inputs:** Raw series metadata files (JSON, XML, or other supported formats)
- **Outputs:** Normalized series files (JSON), logs, and status reports
- **Downstream:** Series grinder, enrichment, and database ingest workers

### Usage Pattern
- Run after raw series ingest and before enrichment/grinder phases
- Can be invoked directly or by orchestration scripts
- Supports parameterized input (e.g., input file, output directory)

### Key Steps
1. **Input Validation:** Checks for required raw series files
2. **Normalization:** Maps and cleans fields, aligns to schema
3. **Output Generation:** Writes normalized series files to `processed/` or designated output
4. **Status Reporting:** Logs normalization status and errors

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/_workers/series_normalize.ps1 -InputFile raw/series.index.raw.json -OutputDir processed/
```

### Governance & Compliance
- All normalization steps are logged for traceability
- No direct database writes; outputs are staged for downstream ingestion
- Follows fail-open policy for partial normalization

### CVI/Registry Metadata
- **process_name:** series_normalize_worker
- **domain:** content_normalization
- **topic:** series_processing
- **unit_type:** worker

### Troubleshooting
- Check input file paths and permissions
- Review logs for error details
- Ensure output directory is writable

---
**Last updated:** 2026-02-02
