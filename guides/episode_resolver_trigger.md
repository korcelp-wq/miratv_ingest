# MiraTV Episode Resolver Trigger Guide

## Component: 9episode_resolver_trigger.ps1

### Purpose
Triggers the episode resolver pipeline for series, mapping and resolving episode metadata for downstream processing and enrichment.

### Location
`C:/miratv_ingest/triggers/9episode_resolver_trigger.ps1`

### Operational Context
- **Domain:** Pipeline Trigger / Episode Resolution
- **Trigger:** Manual or orchestrated by batch scripts or spine
- **Inputs:** Series/season metadata files
- **Outputs:** Resolved episode data, logs status
- **Downstream:** Enrichment, embedding, ingest workers

### Usage Pattern
- Run to resolve episodes for a batch of series/seasons
- Supports parameterized input (e.g., input file, series ID)

### Key Steps
1. **Input Validation:** Checks input file and parameters
2. **Triggering:** Initiates episode resolution for each series/season
3. **Status Logging:** Records trigger status and errors

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/triggers/9episode_resolver_trigger.ps1 -InputFile processed/series_42_seasons.json
```

### Governance & Compliance
- All trigger events are logged for traceability
- No direct database writes; only triggers downstream workers
- Follows fail-open policy for partial resolution

### CVI/Registry Metadata
- **process_name:** episode_resolver_trigger
- **domain:** pipeline_trigger
- **topic:** episode_resolution
- **unit_type:** trigger

### Troubleshooting
- Check input file and permissions
- Review logs for error details
- Ensure downstream workers are present and executable

---
**Last updated:** 2026-02-02
