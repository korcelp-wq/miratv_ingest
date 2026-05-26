# MiraTV Simple Log Utility Guide

## Component: shared/simple_log.ps1

### Purpose
Provides simple logging functions for use by multiple workers and pipeline scripts. Centralizes logic for writing, formatting, and rotating log files.

### Location
`C:/miratv_ingest/shared/simple_log.ps1`

### Operational Context
- **Domain:** Logging / Shared Utilities
- **Trigger:** Called by other scripts or workers as a module
- **Inputs:** Log messages, event data
- **Outputs:** Log files (append-only), optionally with rotation
- **Downstream:** Local log files, audit trails

### Usage Pattern
- Imported or dot-sourced by other PowerShell scripts
- Provides functions for writing and formatting log entries
- Not intended for direct standalone execution

### Key Steps
1. **Log Writing:** Functions to append messages to log files
2. **Formatting:** Ensures consistent log entry structure
3. **Rotation:** Optionally rotates logs based on size or date

### Example Usage
```powershell
. C:/miratv_ingest/shared/simple_log.ps1
Write-Log -Message 'Pipeline started' -Level 'INFO'
```

### Governance & Compliance
- All log entries are append-only for auditability
- No direct database writes; logs are local only
- Follows fail-open policy for partial data

### CVI/Registry Metadata
- **process_name:** shared_simple_log_utility
- **domain:** logging
- **topic:** shared_utilities
- **unit_type:** module

### Troubleshooting
- Check calling script for correct import
- Review log file permissions and disk space
- Ensure log rotation settings are appropriate

---
**Last updated:** 2026-02-02
