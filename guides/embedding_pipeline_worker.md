# MiraTV Embedding Pipeline Worker Guide

## Component: embedding_pipeline.ps1

### Purpose
Automates the embedding pipeline for series, VOD, or live content in the MiraTV ingest system. This worker script is responsible for triggering embedding jobs, managing input/output files, and coordinating with downstream AI or vectorization services.

### Location
`C:/miratv_ingest/workers/embedding_pipeline.ps1`

### Operational Context
- **Domain:** Content Enrichment / Vectorization
- **Trigger:** Manual or orchestrated via spine scheduler or batch triggers
- **Inputs:** Processed content files (JSON, text, or other supported formats)
- **Outputs:** Embedding vectors, logs, and status reports (typically in `processed/` or `tmp/`)
- **Downstream:** May call external AI embedding APIs (Cohere, OpenAI) or local embedding workers

### Usage Pattern
- Run as part of the enrichment phase after grinder/normalization
- Can be invoked directly or by orchestration scripts in `triggers/` or `spine/`
- Supports parameterized input (e.g., target file, embedding model)

### Key Steps
1. **Input Validation:** Checks for required input files and parameters
2. **Embedding Job Launch:** Calls embedding service or script, passing content for vectorization
3. **Output Handling:** Stores resulting vectors and logs in designated output directories
4. **Status Reporting:** Writes job status and errors to spool or log files for auditability

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/workers/embedding_pipeline.ps1 -InputFile processed/series_42.json -Model embed-english-v3.0
```

### Governance & Compliance
- All embedding jobs are logged for traceability
- No direct database writes; outputs are staged for ingestion by downstream workers
- Follows fail-open policy for partial results (unknowns are preserved)

### CVI/Registry Metadata
- **process_name:** embedding_pipeline_worker
- **domain:** content_enrichment
- **topic:** embedding_vectorization
- **unit_type:** worker

### Troubleshooting
- Check input file paths and permissions
- Review logs in `reports/` or `tmp/` for error details
- Ensure downstream embedding services are reachable

---
**Last updated:** 2026-02-02
