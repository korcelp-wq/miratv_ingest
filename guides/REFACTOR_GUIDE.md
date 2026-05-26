# API Refactoring Guide — Modular + Telemetry

## Overview

This guide shows how to refactor the existing Xtream API files to be modular and telemetry-enabled without breaking functionality.

---

## Step 1: Add Telemetry to Current Implementation

### Before (xtream_api_gateway.php):
```php
$result = $handler->getLiveCategories();
echo $result;
```

### After:
```php
require_once __DIR__ . '/shared/telemetry.php';

Telemetry::start('api', 'get_live_categories', ['user' => $username]);
$result = $handler->getLiveCategories();
Telemetry::complete(true, substr_count($result, '{'), 'Success');
echo $result;
```

---

## Step 2: Modular Structure (Target)

```
/_workers/
  /ai/                      # Xtream API (current)
    player_api.php          # Pure dispatcher
    xtream_api_gateway.php  # (deprecated, replaced by dispatcher)
    
  /handlers/                # Domain handlers
    live.php                # get_categories(), get_streams()
    vod.php                 # get_categories(), get_streams()
    series.php              # get_categories(), get_series(), get_series_info()
    
  /shared/                  # Shared utilities
    telemetry.php           # Telemetry functions
    response.php            # JSON normalization
    db.php                  # DB connection (reuse xtream_db_config.php)
    
  /telemetry/               # Telemetry endpoint
    record.php              # Receives and stores telemetry events
    
  telemetry_config.json     # Config file
```

---

## Step 3: Migration Path (Phased)

### Phase 1: Add Telemetry (No Breaking Changes)
- Add `Telemetry::start/complete` to existing `xtream_api_gateway.php`
- Deploy telemetry endpoint (`record.php`)
- Verify events are being recorded in `job_events` table

### Phase 2: Extract Handlers
- Create `/handlers/live.php`, `/vod.php`, `/series.php`
- Move logic from `XtreamApiHandler` into handler files
- Update `xtream_api_gateway.php` to call handlers

### Phase 3: Pure Dispatcher
- Create new `player_api.php` (pure dispatcher)
- Route all requests through new dispatcher
- Deprecate `xtream_api_gateway.php` (keep for compatibility)

### Phase 4: Retire Old Files
- Once verified, remove `xtream_api_gateway.php`
- Consolidate DB connections

---

## Step 4: PowerShell Workers Telemetry

### Before (any worker):
```powershell
Write-Host "Starting job..."
# Do work
Write-Host "Job complete"
```

### After:
```powershell
Import-Module "$PSScriptRoot/shared/telemetry.ps1"

$jobId = Start-JobTelemetry -Component "grinder" -JobName "normalize_series"

try {
    Record-TelemetryCheckpoint -CheckpointName "parse_raw_files"
    # Do work
    
    Complete-JobTelemetry -Success $true -Stats @{ files_processed = 42 }
} catch {
    Record-TelemetryError -ErrorMessage $_.Exception.Message
    Complete-JobTelemetry -Success $false -Message "Job failed"
    throw
}
```

---

## Step 5: Wrapper Pattern (Easiest Retrofit)

### PowerShell:
```powershell
Import-Module "$PSScriptRoot/shared/telemetry.ps1"

Invoke-WithTelemetry -Component "grinder" -JobName "normalize_series" -ScriptBlock {
    # All your existing code here
    # Telemetry is automatic
}
```

### PHP:
```php
require_once __DIR__ . '/shared/telemetry.php';

$result = Telemetry::wrap('api', 'get_live_categories', function() use ($handler) {
    return $handler->getLiveCategories();
}, ['user' => $username]);

echo $result;
```

---

## Step 6: Testing Telemetry

### Verify Config:
```powershell
cat c:\Android_Projects\MiraTV_project_PHASES_1_8\server_deploy\_workers\telemetry_config.json
```

### Test PowerShell:
```powershell
Import-Module "c:\Android_Projects\MiraTV_project_PHASES_1_8\server_deploy\_workers\shared\telemetry.ps1"
Start-JobTelemetry -Component "test" -JobName "test_job"
Complete-JobTelemetry -Success $true -Stats @{ test = 1 }
```

### Test PHP:
```php
require_once '/path/to/shared/telemetry.php';
Telemetry::start('test', 'test_job');
Telemetry::complete(true, 0, 'Test success');
```

### Check Database:
```sql
USE xpdgxfsp_ops;
SELECT * FROM job_events ORDER BY created_at DESC LIMIT 10;
```

---

## Step 7: Monitoring Dashboard (Future)

Once telemetry is live, you can query:

```sql
-- Most called actions
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS action,
    COUNT(*) AS call_count
FROM job_events
WHERE event_type = 'success'
GROUP BY action
ORDER BY call_count DESC;

-- Average response time
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS action,
    AVG(JSON_EXTRACT(event_detail, '$.metadata.duration_ms')) AS avg_ms
FROM job_events
WHERE event_type = 'success'
GROUP BY action;

-- Error rate
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.component')) AS component,
    SUM(CASE WHEN event_type = 'failure' THEN 1 ELSE 0 END) AS failures,
    COUNT(*) AS total,
    (SUM(CASE WHEN event_type = 'failure' THEN 1 ELSE 0 END) / COUNT(*)) * 100 AS error_rate_pct
FROM job_events
GROUP BY component;
```

---

## Step 8: Deployment Checklist

- [ ] Upload `telemetry_config.json` (update token!)
- [ ] Upload `/shared/telemetry.php`
- [ ] Upload `/telemetry/record.php`
- [ ] Create `api_calls` table in `xpdgxfsp_ops` (if doesn't exist)
- [ ] Add telemetry to `xtream_api_gateway.php` (Phase 1)
- [ ] Test one endpoint
- [ ] Roll out to all endpoints
- [ ] Add telemetry to PowerShell workers
- [ ] Verify events in database
- [ ] Build monitoring queries

---

## Notes

- **Non-Breaking**: Telemetry wraps existing code, doesn't replace it
- **Opt-Out**: Set `"enabled": false` in config to disable
- **Async**: PHP telemetry uses async curl (no performance hit)
- **Batching**: Events are batched (default: 10 events per flush)
- **Self-Healing**: Failed flushes keep buffer for retry

---

**Status**: Infrastructure ready. Apply to existing files next.
