# MiraTV Shared Telemetry Worker Guide

## Component: shared/telemetry.ps1

### Purpose
Provides shared telemetry collection and reporting functions for use by multiple workers and pipeline scripts. Centralizes logic for reading, aggregating, and posting telemetry events.

### Location
`C:/miratv_ingest/shared/telemetry.ps1`

### Operational Context
- **Domain:** Telemetry / Shared Utilities
- **Trigger:** Called by other scripts or workers as a module
- **Inputs:** Telemetry event data, log files, or direct calls
- **Outputs:** Aggregated telemetry reports, logs, or server posts
- **Downstream:** Server telemetry endpoints, local audit logs

### Usage Pattern
- Imported or dot-sourced by other PowerShell scripts
- Provides functions for event collection, aggregation, and reporting
- Not intended for direct standalone execution

### Key Steps
1. **Event Collection:** Functions to read and parse telemetry events
2. **Aggregation:** Summarizes metrics for reporting
3. **Reporting:** Sends telemetry summaries to server or writes to logs

### Example Usage
```powershell
. C:/miratv_ingest/shared/telemetry.ps1
Send-TelemetryEvent -EventType 'pipeline_start' -Details $details
```

### Governance & Compliance
- All telemetry events are logged for auditability
- No direct database writes; reporting is append-only
- Follows fail-open policy for partial data

### CVI/Registry Metadata
- **process_name:** shared_telemetry_worker
- **domain:** telemetry
- **topic:** shared_utilities
- **unit_type:** module

### Troubleshooting
- Check calling script for correct import
- Review logs for error details
- Ensure server endpoints are reachable if remote reporting is enabled

---
**Last updated:** 2026-02-02
