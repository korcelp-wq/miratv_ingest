# MiraTV Telemetry Watcher Worker Guide

## Component: telemetry_watcher.ps1

### Purpose
Monitors and collects telemetry data from various pipeline stages and workers in the MiraTV ingest system. This script is responsible for aggregating operational metrics, error events, and performance data, then forwarding them to the appropriate reporting or logging endpoints.

### Location
`C:/miratv_ingest/telemetry_watcher.ps1`

### Operational Context
- **Domain:** Telemetry / Monitoring
- **Trigger:** Manual, scheduled, or orchestrated by pipeline spine
- **Inputs:** Log files, spool files, or direct worker output
- **Outputs:** Aggregated telemetry reports, status logs, and event notifications
- **Downstream:** May post to server telemetry endpoints or local audit logs

### Usage Pattern
- Run periodically or in response to pipeline events
- Can be invoked by orchestration scripts or as a standalone monitor
- Supports parameterized input (e.g., target log, time window)

### Key Steps
1. **Data Collection:** Reads logs, spools, or worker outputs for telemetry events
2. **Aggregation:** Summarizes metrics (counts, errors, durations)
3. **Reporting:** Sends telemetry summaries to server or writes to local logs
4. **Alerting:** Optionally triggers notifications on error thresholds

### Example Invocation
```powershell
powershell -File C:/miratv_ingest/telemetry_watcher.ps1 -LogFile reports/pipeline.log -Window 24h
```

### Governance & Compliance
- All telemetry events are logged for auditability
- No direct database writes; reporting is append-only
- Follows fail-open policy for partial data

### CVI/Registry Metadata
- **process_name:** telemetry_watcher_worker
- **domain:** telemetry
- **topic:** pipeline_monitoring
- **unit_type:** worker

### Troubleshooting
- Check log file paths and permissions
- Review output logs for error details
- Ensure server endpoints are reachable if remote reporting is enabled

---
**Last updated:** 2026-02-02
