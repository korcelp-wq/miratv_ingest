# MiraTV Raw Table Parse Trigger Guide

## Component: 8raw_table_parse_trigger.ps1

### Purpose
Triggers the parsing of raw table data (series, VOD, live) into structured formats for downstream processing. Used to convert provider raw data into normalized or semi-normalized tables.

### Location
`C:/miratv_ingest/triggers/8raw_table_parse_trigger.ps1`

### Operational Context
- **Domain:** Pipeline Trigger / Table Parsing
- **Trigger:** Manual or orchestrated by batch scripts or spine
- **Inputs:** Raw table data files
- **Outputs:** Parsed/structured data files, logs status
- **Downstream:** Normalization, grinder, enrichment workers

### Usage Pattern
- Run to parse new raw table data
- Supports parameterized input (e.g., table type, input file)

### Key Steps
1. **Input Validation:** Checks input file and parameters
2. **Triggering:** Initiates parsing of raw table data
3. **Status Logging:** Records trigger status and errors

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/triggers/8raw_table_parse_trigger.ps1 -TableType series -InputFile raw/series.index.raw.json
```

### Governance & Compliance
- All trigger events are logged for traceability
- No direct database writes; only triggers downstream workers
- Follows fail-open policy for partial parsing

### CVI/Registry Metadata
- **process_name:** raw_table_parse_trigger
- **domain:** pipeline_trigger
- **topic:** table_parsing
- **unit_type:** trigger

### Troubleshooting
- Check input file and permissions
- Review logs for error details
- Ensure downstream workers are present and executable

---
**Last updated:** 2026-02-02
