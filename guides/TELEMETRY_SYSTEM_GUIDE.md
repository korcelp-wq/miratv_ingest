# MiraTV Telemetry System Guide

## What We're Logging

The system tracks three types of operational events:

### 1. **OPS Events** (`ops_spool/`)
- Pipeline operations and workflow events
- Examples: `LOOP_START`, `SERIES_RUN_SUCCESS`, `SERIES_RUN_FAILED`, `LOOP_END`
- Used for: Job tracking, failure detection, orchestration monitoring

### 2. **LAKE Events** (`lake_spool/`)
- Knowledge and signal events
- Examples: `SERIES_LOCK_ACQUIRED`, `SUCCESS`, `FAILURE`
- Used for: Semantic tracking, telemetry, AI signal generation

### 3. **IGM Events** (`igm_spool/`)
- Governance and attestation events
- Examples: Canon rule validations, compliance checks
- Used for: Rule enforcement tracking, governance audit trail

---

## How It Works

### Architecture (No JSON Processes)
```
Batch File (.bat)
    ↓
Calls: Emit-Ops/Emit-Lake/Emit-IGM
    ↓
Writes pipe-delimited text to spool files
    ↓
upload_spool_once.ps1 reads spool files
    ↓
Streams via HTTP POST to CVI endpoint
    ↓
Database: xpdgxfsp_callosum_matrix
    (cm_requests + cm_documents tables)
```

### File Locations
- **Emit Module**: `c:\miratv_ingest\_workers\_accessories.psm1`
- **Spool Directories**: 
  - `c:\miratv_ingest\ops_spool\`
  - `c:\miratv_ingest\lake_spool\`
  - `c:\miratv_ingest\igm_spool\`
- **Uploader**: `c:\miratv_ingest\upload_spool_once.ps1`
- **Endpoint**: `https://miratv.club/_workers/cvi_request.php`
- **Database**: `xpdgxfsp_callosum_matrix` (MySQL)

### Spool File Format (Pipe-Delimited)
```
2026-01-30T08:15:23.456-07:00 | master_runner_loop | LOOP_START | 
2026-01-30T08:15:45.123-07:00 | master_runner_loop | SERIES_RUN_SUCCESS | series_id=42
```

Fields: `timestamp | component | event | optional_fields`

---

## Using the System

### In Batch Files
```batch
@echo off
set ACCESSORY_PS=C:\miratv_ingest\_workers\_accessories.psm1
set COMPONENT=my_component

REM Log an ops event
call pwsh -NoProfile -Command "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'EVENT_NAME' '%COMPONENT%'"

REM Log a lake signal
call pwsh -NoProfile -Command "Import-Module '%ACCESSORY_PS%'; Emit-Lake 'SIGNAL_NAME' '%COMPONENT%'"

REM Log with extra fields (optional)
call pwsh -NoProfile -Command "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'PROCESS_COMPLETE' '%COMPONENT%' @{series_id=42; duration=10}"
```

### Manual Upload
```powershell
# Upload accumulated spool files immediately
pwsh -NoProfile -File "c:\miratv_ingest\upload_spool_once.ps1"
```

### Automatic Upload
Currently triggered at the end of `master_runner2.bat` processing (Step 07 commented out, replaced with streaming).

---

## Tweaking the System

### Add New Event Types
Edit `_accessories.psm1` - all three functions follow the same pattern:
```powershell
function Emit-Ops {
    param(
        [string]$Event,
        [string]$Component,
        [hashtable]$Fields = @{}
    )
    $fieldStr = ($Fields.Keys | ForEach-Object { "$_=$($Fields[$_])" }) -join " | "
    Write-Line $OPS "ops" "$(NowIso) | $Component | $Event | $fieldStr"
}
```

### Change Upload Frequency
**Option A**: Call uploader more frequently in batch files
```batch
REM After each major step
call pwsh -NoProfile -File "c:\miratv_ingest\upload_spool_once.ps1"
```

**Option B**: Run continuous background uploader
```powershell
# Start persistent uploader (monitors every 5 seconds)
pwsh -NoProfile -File "c:\miratv_ingest\spool_uploader.ps1"
```

### Adjust Spool File Names
In `_accessories.psm1`, change the `Write-Line` function:
```powershell
$date = (Get-Date).ToString("yyyyMMdd")  # Daily files
# OR
$date = (Get-Date).ToString("yyyyMMddHH")  # Hourly files
```

### Change Database Target
Edit `upload_spool_once.ps1`:
```powershell
$CVI_ENDPOINT = "https://miratv.club/_workers/cvi_request.php"
$TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
```

### Filter What Gets Uploaded
Edit `upload_spool_once.ps1` to skip certain events:
```powershell
foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -like "*CHECKPOINT*") { continue }  # Skip checkpoints
    
    # Upload remaining events
    curl.exe -X POST "$CVI_ENDPOINT?token=$TOKEN" ...
}
```

---

## Database Schema

### Tables
1. **cm_routines** - Event type definitions
   - `routine_id`, `routine_name`, `target_db`, `active`

2. **cm_documents** - Event context storage
   - `document_id`, `body` (stores pipe-delimited line), `source_actor`, `created_at`

3. **cm_requests** - Event log entries
   - `request_id`, `routine_id`, `request_document_id`, `requested_by`, `status`, `created_at`

### Query Recent Events
```sql
SELECT r.request_id, rt.routine_name, r.requested_by, 
       d.body as context, r.created_at
FROM cm_requests r
JOIN cm_routines rt ON r.routine_id = rt.routine_id
LEFT JOIN cm_documents d ON r.request_document_id = d.document_id
ORDER BY r.created_at DESC
LIMIT 100;
```

---

## Troubleshooting

### Spool Files Not Being Created
- Check if `_accessories.psm1` is being loaded correctly
- Verify spool directories exist: `ops_spool/`, `lake_spool/`, `igm_spool/`
- Test manually: `pwsh -Command "Import-Module 'c:\miratv_ingest\_workers\_accessories.psm1'; Emit-Ops 'TEST' 'manual'"`

### Spool Files Not Uploading
- Run uploader manually: `pwsh -File "c:\miratv_ingest\upload_spool_once.ps1"`
- Check if files are in spool directories: `ls c:\miratv_ingest\*_spool\*.log`
- Verify CVI endpoint is accessible: `curl https://miratv.club/_workers/cvi_request.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY`

### Database Not Receiving Data
- Upload updated CVI endpoint: `curl --ftp-create-dirs -T "c:\MiraTV_infrastructure\_workers\cvi_request.php" --user "automated:=tS8nA4yb8]~" "ftp://miratv.club/public_html/_workers/cvi_request.php"`
- Check server logs for PHP errors
- Test endpoint directly: `curl -X POST "https://miratv.club/_workers/cvi_request.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" -H "Content-Type: text/plain" -d "2026-01-30T08:00:00-07:00 | test | TEST_EVENT | "`

### Too Many Spool Files Accumulating
- Increase upload frequency
- Check if uploader is being called in batch files
- Verify processed files are being moved to `processed/` directory

---

## Key Principles

✅ **DO**:
- Use pipe-delimited text format (no JSON parsing in batch files)
- Call Emit functions from batch files via PowerShell module
- Let uploader handle streaming to database
- Keep batch files as pure orchestrators

❌ **DON'T**:
- Add JSON processing to batch files
- Parse or modify spool files in batch files
- Call database directly from batch files
- Skip the module and write to spool files directly

---

## Contact / Support

For issues or enhancements, check:
- Main orchestration: `master_runner_loop_acc.bat`
- Emit module: `_accessories.psm1`
- Uploader: `upload_spool_once.ps1`
- Server endpoint: `_workers/cvi_request.php`
