# Telemetry System - Complete Package

## 🎯 What We Built

A **universal telemetry system** that tracks everything across your entire MiraTV infrastructure:

### 🔹 PowerShell Workers → Telemetry
- All batch scripts report job start/progress/complete
- Checkpoints track workflow stages
- Errors captured with full context
- Stats collected (files processed, success rate, etc.)

### 🔹 Web Endpoints → Telemetry
- All API calls tracked (action, user, duration, items)
- Errors logged with stack traces
- Response times measured
- Success/failure rates tracked

### 🔹 Centralized Storage
- All telemetry goes to `xpdgxfsp_ops.job_events`
- Queryable, analyzable, ready for dashboards
- Feeds your Living Context System (future)

---

## 📦 Package Contents

### Configuration
```
telemetry_config.json       # Central config (UPDATE TOKEN!)
```

### Core Libraries
```
shared/telemetry.ps1        # PowerShell module
shared/telemetry.php        # PHP class
```

### Recording Endpoint
```
telemetry/record.php        # HTTP endpoint for event storage
```

### Updated Files (Examples)
```
ai/xtream_api_gateway.php   # ✅ Now reports all API calls
workers/embedding_pipeline.ps1  # ✅ Now reports job lifecycle
```

### Documentation
```
REFACTOR_GUIDE.md           # How to add telemetry to any file
TELEMETRY_DEPLOYMENT.md     # Deployment checklist
TELEMETRY_COMPLETE.md       # This file
```

### Utilities
```
deploy_local.ps1            # Copy telemetry to local ingest folder
test_endpoints.ps1          # Test API endpoints
```

---

## 🚀 Quick Start

### 1. Deploy Locally (Test PowerShell Workers)
```powershell
cd c:\Android_Projects\MiraTV_project_PHASES_1_8\server_deploy\_workers
.\deploy_local.ps1 -Force

# Edit config token
notepad c:\miratv_ingest\telemetry_config.json

# Test
cd c:\miratv_ingest\workers
.\embedding_pipeline.ps1 -BatchSize 5
```

### 2. Deploy to Server (Enable Web Telemetry)
```
Upload to: public_html/_workers/

Files:
  ├── telemetry_config.json  (UPDATE TOKEN FIRST!)
  ├── shared/
  │   └── telemetry.php
  ├── telemetry/
  │   └── record.php
  └── ai/
      └── xtream_api_gateway.php (updated)
```

### 3. Verify
```sql
USE xpdgxfsp_ops;
SELECT * FROM job_events ORDER BY created_at DESC LIMIT 10;
```

---

## 📊 What You'll See

### API Telemetry Example
```json
{
  "event_type": "success",
  "component": "api",
  "job_name": "get_live_categories",
  "message": "Success",
  "timestamp": "2026-01-29T14:32:00Z",
  "metadata": {
    "user": "Marina2025",
    "duration_ms": 45.23,
    "row_count": 12
  }
}
```

### Worker Telemetry Example
```json
{
  "event_type": "success",
  "component": "workers",
  "job_name": "embedding_pipeline",
  "message": "Embedding cycle completed",
  "timestamp": "2026-01-29T14:35:22Z",
  "metadata": {
    "duration_ms": 7000.12,
    "stats": {
      "pending_count": 10,
      "success_count": 10,
      "fail_count": 0
    }
  }
}
```

---

## 🔍 Useful Queries

### Most Called API Actions
```sql
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS action,
    COUNT(*) AS calls
FROM job_events
WHERE JSON_EXTRACT(event_detail, '$.component') = 'api'
  AND created_at >= NOW() - INTERVAL 24 HOUR
GROUP BY action
ORDER BY calls DESC;
```

### Worker Success Rate
```sql
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS worker,
    SUM(CASE WHEN event_type = 'success' THEN 1 ELSE 0 END) AS successes,
    SUM(CASE WHEN event_type = 'failure' THEN 1 ELSE 0 END) AS failures,
    ROUND((SUM(CASE WHEN event_type = 'success' THEN 1 ELSE 0 END) / COUNT(*)) * 100, 2) AS success_rate
FROM job_events
WHERE JSON_EXTRACT(event_detail, '$.component') = 'workers'
GROUP BY worker;
```

### Slowest API Endpoints
```sql
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS action,
    ROUND(AVG(JSON_EXTRACT(event_detail, '$.metadata.duration_ms')), 2) AS avg_ms,
    ROUND(MAX(JSON_EXTRACT(event_detail, '$.metadata.duration_ms')), 2) AS max_ms
FROM job_events
WHERE JSON_EXTRACT(event_detail, '$.component') = 'api'
  AND event_type = 'success'
GROUP BY action
ORDER BY avg_ms DESC;
```

### Recent Errors
```sql
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.component')) AS component,
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.job_name')) AS job,
    JSON_UNQUOTE(JSON_EXTRACT(event_detail, '$.message')) AS error,
    created_at
FROM job_events
WHERE event_type = 'failure'
ORDER BY created_at DESC
LIMIT 20;
```

---

## 🎓 How to Add Telemetry to New Files

### PowerShell Pattern
```powershell
Import-Module "$PSScriptRoot/../shared/telemetry.ps1"

$jobId = Start-JobTelemetry -Component "grinder" -JobName "my_worker"

try {
    Record-TelemetryCheckpoint -CheckpointName "stage_1"
    # ... do work ...
    
    Complete-JobTelemetry -Success $true -Stats @{ files = 42 }
} catch {
    Record-TelemetryError -ErrorMessage $_.Exception.Message
    Complete-JobTelemetry -Success $false
    throw
}
```

### PHP Pattern
```php
require_once __DIR__ . '/../shared/telemetry.php';

Telemetry::start('api', 'my_action', ['user' => $username]);

try {
    Telemetry::checkpoint('fetch_from_db');
    // ... do work ...
    
    Telemetry::complete(true, $rowCount, 'Success');
} catch (Exception $e) {
    Telemetry::recordError($e->getMessage());
    Telemetry::complete(false, 0, $e->getMessage());
    throw $e;
}
```

### Wrapper Pattern (Simplest)
```powershell
# PowerShell
Invoke-WithTelemetry -Component "test" -JobName "test_job" -ScriptBlock {
    # All your code here - telemetry is automatic
}
```

```php
// PHP
$result = Telemetry::wrap('api', 'test_action', function() {
    // All your code here - telemetry is automatic
    return $data;
});
```

---

## 🔐 Security Checklist

- [ ] Change default token in `telemetry_config.json`
- [ ] Update token in `telemetry/record.php` (or use env variable)
- [ ] Restrict access to `/telemetry/` folder (`.htaccess` or IP whitelist)
- [ ] Enable HTTPS for all telemetry endpoints
- [ ] Add data retention policy (delete events > 30 days)

---

## 🏗️ Architecture Benefits

### Before Telemetry
```
Worker runs → ??? → Success/Failure (maybe logs show something)
API called → ??? → Response returned (no metrics)
```

### After Telemetry
```
Worker runs → START event → CHECKPOINT events → SUCCESS/FAILURE event
              ↓
           xpdgxfsp_ops.job_events
              ↓
           Queryable, analyzable, feeds Living Context System
```

### This Enables
✅ **Real-time monitoring** (see what's running right now)  
✅ **Performance tracking** (spot slowdowns before they're critical)  
✅ **Error visibility** (know immediately when something fails)  
✅ **Usage analytics** (which endpoints are used most?)  
✅ **Living Context** (AI reads telemetry to understand system health)  
✅ **Governance** (detect pressure points, validate rules)  

---

## 🎯 Next Actions

### Immediate
1. Deploy locally → test PowerShell telemetry
2. Upload to server → test web telemetry
3. Verify events in database

### Short-term
4. Add telemetry to remaining workers (use patterns from `embedding_pipeline.ps1`)
5. Add telemetry to other PHP endpoints (use patterns from `xtream_api_gateway.php`)
6. Build basic monitoring queries

### Long-term
7. Create monitoring dashboard
8. Set up automated alerts (error rate, latency)
9. Feed telemetry into Living Context System
10. Use telemetry for AI-driven optimization

---

## 📄 Files Summary

| File | Purpose | Location |
|------|---------|----------|
| `telemetry_config.json` | Central configuration | Server + Local |
| `shared/telemetry.ps1` | PowerShell module | Local workers |
| `shared/telemetry.php` | PHP class | Server web root |
| `telemetry/record.php` | Event storage endpoint | Server web root |
| `xtream_api_gateway.php` | Updated API gateway | Server web root |
| `embedding_pipeline.ps1` | Updated worker | Local workers |
| `deploy_local.ps1` | Local deployment script | Dev machine |
| `test_endpoints.ps1` | API test script | Dev machine |
| `REFACTOR_GUIDE.md` | How-to guide | Documentation |
| `TELEMETRY_DEPLOYMENT.md` | Deployment checklist | Documentation |
| `TELEMETRY_COMPLETE.md` | This summary | Documentation |

---

## ✅ Status

**Infrastructure**: ✅ Complete  
**Examples**: ✅ Complete (API + Worker)  
**Documentation**: ✅ Complete  
**Testing Tools**: ✅ Complete  
**Ready to Deploy**: ✅ Yes

---

**Built**: 2026-01-29  
**System**: MiraTV Universal Telemetry  
**Coverage**: PowerShell Workers + PHP Web Endpoints  
**Storage**: xpdgxfsp_ops.job_events  
**Future**: Feeds Living Context System, enables AI-driven optimization
