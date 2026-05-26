# MiraTV Telemetry System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MiraTV Universal Telemetry                        │
│                     Everything Reports Now                            │
└─────────────────────────────────────────────────────────────────────┘

┌────────────────────────┐
│  PowerShell Workers    │
│  (Local)               │
├────────────────────────┤
│ • embedding_pipeline   │──┐
│ • normalize_series     │  │
│ • parse_episodes       │  │
│ • spine_scheduler      │  │
│ • ... (all workers)    │  │
└────────────────────────┘  │
          ↓                 │
   Import telemetry.ps1     │
          ↓                 │
   Start → Checkpoint → End │
                            │
                            ├─→ POST https://miratv.club/_workers/telemetry/record.php
                            │
┌────────────────────────┐  │
│  PHP Web Endpoints     │  │
│  (Server)              │  │
├────────────────────────┤  │
│ • player_api.php       │──┘
│ • get_live_categories  │
│ • get_series_info      │
│ • ... (all endpoints)  │
└────────────────────────┘
          ↓
   Include telemetry.php
          ↓
   Start → Work → Complete
   
                ↓
                
┌────────────────────────────────────────────────────────────────────┐
│                      Telemetry Recorder                             │
│                  /_workers/telemetry/record.php                     │
│                                                                     │
│  • Validates token                                                  │
│  • Receives event batch (JSON)                                     │
│  • Stores in xpdgxfsp_ops.job_events                              │
└────────────────────────────────────────────────────────────────────┘
                
                ↓
                
┌────────────────────────────────────────────────────────────────────┐
│                      Database Storage                                │
│                   xpdgxfsp_ops.job_events                           │
│                                                                     │
│  Columns:                                                           │
│    • job_key         (action name)                                 │
│    • event_type      (start, checkpoint, success, failure)         │
│    • event_detail    (JSON with metadata)                          │
│    • created_at      (timestamp)                                    │
│                                                                     │
│  Stores:                                                            │
│    • API calls (user, action, duration, items)                     │
│    • Worker jobs (component, job, stats, errors)                   │
│    • Errors (type, message, context, stack trace)                  │
│    • Checkpoints (progress markers)                                │
└────────────────────────────────────────────────────────────────────┘

                ↓
                
┌────────────────────────────────────────────────────────────────────┐
│                          Consumers                                   │
├────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  📊 Monitoring Queries                                             │
│     • Success rates                                                 │
│     • Average response times                                        │
│     • Error trends                                                  │
│     • Usage patterns                                                │
│                                                                     │
│  🔔 Alerts                                                         │
│     • Error rate > 15%                                             │
│     • Latency > 5 seconds                                          │
│     • No jobs in last hour                                         │
│                                                                     │
│  🤖 Living Context System (Future)                                │
│     • NeuroNet reads patterns                                      │
│     • Governance sees pressure                                     │
│     • AI detects drift                                             │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

---

## Event Flow Example

```
14:32:00.000 │ User: curl get_live_categories
             │
             ↓
14:32:00.012 │ player_api.php
             │   → Telemetry::start('api', 'get_live_categories', user='Marina2025')
             │   → Calls sp_xtream_get_live_categories()
             │
             ↓
14:32:00.045 │ Database returns 12 categories (45ms)
             │   → Telemetry::complete(true, 12, 'Success')
             │
             ↓
14:32:00.047 │ POST to /telemetry/record.php (async, 2ms)
             │
             ↓
14:32:00.049 │ record.php stores event in job_events
             │
             ↓
14:32:00.050 │ Response sent to client (50ms total)
```

```
Event stored in database:
{
  "event_type": "success",
  "component": "api",
  "job_name": "get_live_categories",
  "message": "Success",
  "timestamp": "2026-01-29T14:32:00.047Z",
  "metadata": {
    "user": "Marina2025",
    "duration_ms": 45.23,
    "row_count": 12,
    "action": "get_live_categories"
  }
}
```

---

## Configuration Flow

```
telemetry_config.json
         ↓
    ┌────────────────────────────────┐
    │ Shared Configuration           │
    ├────────────────────────────────┤
    │ • endpoint URL                 │
    │ • token                        │
    │ • batch size                   │
    │ • thresholds                   │
    │ • component mappings           │
    └────────────────────────────────┘
         ↓                    ↓
    telemetry.ps1       telemetry.php
         ↓                    ↓
    PowerShell Workers   Web Endpoints
```

---

## Data Model

```
job_events table
┌──────────┬─────────────┬────────────────────────────────┬─────────────────────┐
│ id       │ job_key     │ event_type                     │ event_detail (JSON) │
├──────────┼─────────────┼────────────────────────────────┼─────────────────────┤
│ 1001     │ get_live... │ start                          │ {"user": "Marina... │
│ 1002     │ get_live... │ success                        │ {"duration_ms": ... │
│ 1003     │ embedding...│ start                          │ {"batch_size": 5... │
│ 1004     │ embedding...│ checkpoint                     │ {"checkpoint": "... │
│ 1005     │ embedding...│ success                        │ {"stats": {...}...  │
└──────────┴─────────────┴────────────────────────────────┴─────────────────────┘
```

---

## Integration Points

### 1. Living Context System
```
Telemetry Events → Context Snapshots → AI Decision Making
```

### 2. Governance (IGM)
```
Telemetry Patterns → Rule Validation → Attestation Spools
```

### 3. NeuroNet
```
Telemetry Time-Series → Anomaly Detection → Drift Alerts
```

### 4. Ops Orchestration
```
Telemetry Stats → Capacity Planning → Job Scheduling
```

---

## Performance Impact

**PowerShell**: Negligible (~10ms per job)
- Events buffered locally
- Flushed in batches
- Network call async

**PHP**: Minimal (~2ms per request)
- cURL async with 500ms timeout
- Non-blocking
- Batched (default 10 events)

**Database**: Lightweight
- Simple INSERT operations
- Indexed on job_key, event_type, created_at
- JSON field allows flexible querying

---

## Coverage Map

```
MiraTV System Coverage:

✅ Web Layer
   ├─ Xtream API          (✅ telemetry enabled)
   ├─ Ingest Endpoints    (⏳ TODO)
   └─ Admin Panels        (⏳ TODO)

✅ Workers Layer
   ├─ embedding_pipeline  (✅ telemetry enabled)
   ├─ normalize_series    (⏳ TODO)
   ├─ parse_episodes      (⏳ TODO)
   └─ spine_scheduler     (⏳ TODO)

⏳ Database Layer (Future)
   └─ Stored procedures can log internally

✅ Infrastructure
   ├─ Telemetry config    (✅ ready)
   ├─ Recording endpoint  (✅ ready)
   ├─ PS module           (✅ ready)
   └─ PHP class           (✅ ready)
```

---

**This is your system's nervous system—it can now feel what's happening everywhere.**
