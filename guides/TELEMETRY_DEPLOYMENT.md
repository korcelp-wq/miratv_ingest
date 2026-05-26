# Telemetry System - Deployment Summary

## ✅ What's Been Created

### 1. Configuration
- `telemetry_config.json` - Central config for all telemetry settings

### 2. Core Libraries
- **PowerShell**: `shared/telemetry.ps1` - For batch scripts, workers, triggers
- **PHP**: `shared/telemetry.php` - For web endpoints (Xtream API, etc.)

### 3. Recording Endpoint
- `telemetry/record.php` - Receives and stores telemetry events from all components

### 4. Applied to Existing Files
- ✅ `xtream_api_gateway.php` - Now reports all API calls
- ✅ `embedding_pipeline.ps1` - Now reports job start/checkpoints/complete

### 5. Documentation
- `REFACTOR_GUIDE.md` - How to add telemetry to any file
- `TELEMETRY_DEPLOYMENT.md` - This file

---

## 📋 Deployment Checklist

### Step 1: Update Config
```json
// Edit: server_deploy\_workers\telemetry_config.json
"token": "CHANGE_THIS_TO_SECURE_TOKEN"
```

### Step 2: Upload to Server
```
public_html/_workers/
  ├── telemetry_config.json
  ├── shared/
  │   ├── telemetry.php
  │   └── telemetry.ps1  (if you have PowerShell on server)
  ├── telemetry/
  │   └── record.php
  └── ai/
      ├── xtream_api_gateway.php  (updated)
      ├── xtream_api_handler.php
      ├── xtream_db_config.php
      └── player_api.php
```

### Step 3: Create Database Tables

**If `api_calls` table doesn't exist:**
```sql
USE xpdgxfsp_ops;

CREATE TABLE IF NOT EXISTS api_calls (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    job_key VARCHAR(255),
    event_type VARCHAR(50),
    event_detail JSON,
    created_at DATETIME(6) DEFAULT CURRENT_TIMESTAMP(6),
    INDEX idx_job_key (job_key),
    INDEX idx_event_type (event_type),
    INDEX idx_created_at (created_at)
);
```

**Verify `job_events` table exists:**
```sql
SHOW CREATE TABLE xpdgxfsp_ops.job_events;
```

### Step 4: Test Telemetry Endpoint
```powershell
$body = @{
    token = "YOUR_TOKEN_HERE"
    events = @(
        @{
            event_type = "test"
            component = "test"
            job_name = "test_job"
            message = "Test telemetry"
            timestamp = (Get-Date).ToString("o")
        }
    )
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "https://miratv.club/_workers/telemetry/record.php" `
    -Method Post `
    -Body $body `
    -ContentType "application/json"
```

### Step 5: Test API Telemetry
```bash
# Make an API call
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_categories"

# Check database for telemetry event
mysql -u user -p -e "USE xpdgxfsp_ops; SELECT * FROM job_events ORDER BY created_at DESC LIMIT 5;"
```

### Step 6: Test PowerShell Telemetry
```powershell
# Copy telemetry module to local workers directory
Copy-Item "c:\Android_Projects\MiraTV_project_PHASES_1_8\server_deploy\_workers\shared\telemetry.ps1" `
    -Destination "c:\miratv_ingest\shared\" -Force

# Copy config
Copy-Item "c:\Android_Projects\MiraTV_project_PHASES_1_8\server_deploy\_workers\telemetry_config.json" `
    -Destination "c:\miratv_ingest\" -Force

# Run embedding pipeline (already updated)
cd c:\miratv_ingest\workers
.\embedding_pipeline.ps1 -BatchSize 5
```

---

## 🔍 Verification Queries

### Check API Calls
```sql
USE xpdgxfsp_ops;

-- Recent API calls
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS action,
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.metadata.user')) AS user,
    event_type,
    created_at
FROM job_events
WHERE JSON_EXTRACT(event_detail, '$.component') = 'api'
ORDER BY created_at DESC
LIMIT 20;
```

### Check Success Rate
```sql
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.component')) AS component,
    SUM(CASE WHEN event_type = 'success' THEN 1 ELSE 0 END) AS successes,
    SUM(CASE WHEN event_type = 'failure' THEN 1 ELSE 0 END) AS failures,
    COUNT(*) AS total,
    ROUND((SUM(CASE WHEN event_type = 'success' THEN 1 ELSE 0 END) / COUNT(*)) * 100, 2) AS success_rate_pct
FROM job_events
WHERE created_at >= NOW() - INTERVAL 24 HOUR
GROUP BY component;
```

### Check Average Response Time
```sql
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS action,
    COUNT(*) AS calls,
    ROUND(AVG(JSON_EXTRACT(event_detail, '$.metadata.duration_ms')), 2) AS avg_duration_ms,
    ROUND(MAX(JSON_EXTRACT(event_detail, '$.metadata.duration_ms')), 2) AS max_duration_ms
FROM job_events
WHERE event_type = 'success'
  AND JSON_EXTRACT(event_detail, '$.component') = 'api'
  AND created_at >= NOW() - INTERVAL 24 HOUR
GROUP BY action
ORDER BY avg_duration_ms DESC;
```

---

## 📊 What You'll See After Deployment

### API Calls
Every Xtream API call now logs:
- **Action** (get_live_categories, get_series_info, etc.)
- **User** (Marina2025, etc.)
- **Duration** (milliseconds)
- **Item count** (how many items returned)
- **Success/Failure** status

### Worker Jobs
Every PowerShell worker logs:
- **Job start** (component, job name, metadata)
- **Checkpoints** (progress markers)
- **Job complete** (success/failure, stats)
- **Errors** (with context)

### Example Timeline
```
14:32:00 | api | get_live_categories | START  | user=Marina2025
14:32:00 | api | get_live_categories | SUCCESS | duration=45ms, items=12
14:32:15 | workers | embedding_pipeline | START  | batch_size=50
14:32:16 | workers | embedding_pipeline | CHECKPOINT | fetch_pending_embeddings
14:32:18 | workers | embedding_pipeline | CHECKPOINT | cohere_embedding, batch_count=10
14:32:22 | workers | embedding_pipeline | SUCCESS | duration=7000ms, success_count=10
```

---

## 🚀 Next Steps After Deployment

### 1. Add Telemetry to More Workers
Use the pattern from `embedding_pipeline.ps1`:
```powershell
Import-Module "$PSScriptRoot/../shared/telemetry.ps1"
$jobId = Start-JobTelemetry -Component "grinder" -JobName "normalize_series"
# ... your work ...
Complete-JobTelemetry -Success $true -Stats @{ files_processed = 42 }
```

### 2. Add Telemetry to More Web Files
Use the pattern from `xtream_api_gateway.php`:
```php
require_once __DIR__ . '/../shared/telemetry.php';
Telemetry::start('component', 'action_name');
// ... your work ...
Telemetry::complete(true, $rowCount, 'Success');
```

### 3. Build Monitoring Dashboard
Query telemetry data to build:
- **API usage dashboard** (most called endpoints, slowest endpoints)
- **Worker health dashboard** (success rate, average duration)
- **Error tracking** (top failures, error trends)

### 4. Set Up Alerts
Create triggers or scheduled queries:
```sql
-- Alert if error rate > 15%
-- Alert if average latency > 5 seconds
-- Alert if no jobs in last hour (system health)
```

---

## 🔐 Security Notes

1. **Token Protection**: Replace default token in `telemetry_config.json`
2. **Endpoint Access**: Consider adding IP whitelist to `telemetry/record.php`
3. **Data Retention**: Add cleanup job for old telemetry events (>30 days)

---

## 🐛 Troubleshooting

### Issue: Telemetry events not appearing in database
**Check:**
1. Token matches between config and `record.php`
2. `telemetry/record.php` is accessible via HTTP
3. Database connection works in `record.php`
4. `job_events` table exists in `xpdgxfsp_ops`

### Issue: PowerShell telemetry not working
**Check:**
1. `telemetry.ps1` is in correct path
2. `telemetry_config.json` exists and is valid JSON
3. Network allows HTTPS POST to telemetry endpoint

### Issue: PHP telemetry not working
**Check:**
1. `require_once` path is correct
2. File permissions allow reading `telemetry.php`
3. cURL is enabled in PHP

---

## 📁 Files Modified

### New Files
- `server_deploy/_workers/telemetry_config.json`
- `server_deploy/_workers/shared/telemetry.ps1`
- `server_deploy/_workers/shared/telemetry.php`
- `server_deploy/_workers/telemetry/record.php`
- `server_deploy/_workers/ai/REFACTOR_GUIDE.md`
- `server_deploy/_workers/ai/TELEMETRY_DEPLOYMENT.md` (this file)

### Modified Files
- `server_deploy/_workers/ai/xtream_api_gateway.php` (added telemetry)
- `c:\miratv_ingest\workers\embedding_pipeline.ps1` (added telemetry)

---

**Status**: ✅ Ready to deploy
**Next**: Upload files, update token, test endpoints
