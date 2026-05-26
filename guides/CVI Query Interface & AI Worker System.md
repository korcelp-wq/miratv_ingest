# CVI Query Interface & AI Worker System

## Overview

The **CVI (Callosum Vector Integration) Query System** is the interface layer that enables internal AI agents and external systems to query MiraTv's distributed databases. It provides:

- ✅ **Safe, tokenized query gateway** for structured fact retrieval
- ✅ **Per-database stored procedures** that compute deltas and publish perspective reports
- ✅ **Append-only signal spools** that capture real-time governance attestations
- ✅ **PowerShell workers** that invoke queries and capture results
- ✅ **Trigger system** that queues and orchestrates query execution

---

## Architecture

### Query Flow (End-to-End)

```
AI Agent (local or internal)
    ↓
Trigger File (.ps1)
    ↓ (captures query payload)
Worker (cvi_worker.ps1)
    ↓ (invokes HTTP request)
PHP Gateway (cvi_gateway.php)
    ↓ (validates token, whitelists SP name)
Stored Procedure (sp_*.sql)
    ↓ (computes deltas, aggregates metrics)
Result Set (JSON)
    ↓ (logged to audit trail)
Return to Agent (structured facts)
```

### Database Topology

Each of MiraTv's 7 databases now has:

1. **`cvi_carousel` table** – Append-only message bus for CVI publications
   - `message_id` (auto-increment)
   - `published_at` (timestamp)
   - `source_system` (e.g., 'ops', 'governance', 'lake')
   - `message_type` (e.g., 'fact_query', 'signal_publication', 'proposal')
   - `body` (JSON payload)
   - `published_by` (actor: 'system', 'ai_agent', 'human')

2. **`sp_cvi_publish` procedure** – Write facts to the carousel
   ```sql
   sp_cvi_publish(
     @source_system VARCHAR,
     @message_type VARCHAR,
     @body JSON,
     @published_by VARCHAR
   )
   ```

3. **Basic fact procedures** – Read-only queries that surface safe metrics
   - `sp_get_event_count_by_source()`
   - `sp_get_recent_telemetry()`
   - Per-database domain facts (e.g., `sp_get_job_run_counts()`, `sp_get_active_macs_count()`)

---

## Files & Components

### SQL Stored Procedures

**Location**: `AI_WORKERS/sql/`

| File | Database | Purpose |
|------|----------|---------|
| `basic_facts.sql` | xpdgxfsp_lake_vector | Telemetry facts (event counts, recent records) |
| `ops_basic_facts.sql` | xpdgxfsp_ops | Job/pipeline facts (run counts, failures) |
| `cvi/create_cvi_*.sql` (7 files) | Each DB | CVI carousel table + `sp_cvi_publish` proc |
| `cvi/*_basic_facts.sql` (6 files) | Each non-lake DB | Domain-specific fact procedures |
| `perspective_procs.sql` | xpdgxfsp_lake_vector | Delta computation & perspective report (future) |

**Deployment**: Run each script in its target database:
```bash
USE `xpdgxfsp_lake_vector`;
SOURCE AI_WORKERS/sql/basic_facts.sql;
SOURCE AI_WORKERS/sql/cvi/create_cvi_xpdgxfsp_lake_vector.sql;
```

### PHP Gateway

**Location**: `AI_WORKERS/php/cvi_gateway.php`

**Purpose**: Token-authenticated gateway that whitelists safe stored procedures and executes them with parameterized calls.

**Entry Point**:
```
POST /_workers/ai/cvi_gateway.php?token=WORKER_TOKEN
Content-Type: application/json

{
  "procedure": "sp_get_event_count_by_source",
  "params": {
    "source": "ai_telemetry",
    "time_window_hours": 24
  }
}
```

**Response**:
```json
{
  "success": true,
  "procedure": "sp_get_event_count_by_source",
  "rows": [
    { "source": "ai_telemetry", "event_count": 1542, "latest_event": "2026-01-28T14:32:00Z" }
  ],
  "row_count": 1,
  "query_id": "550e8400-e29b-41d4-a716-446655440000",
  "executed_at": "2026-01-28T14:35:22Z"
}
```

**Security**:
- ✅ Token validation (compare against `WORKER_TOKENS` list)
- ✅ Procedure whitelisting (only safe SPs allowed)
- ✅ Parameter binding (prevent SQL injection)
- ✅ Execution timeout (30 seconds)
- ✅ Audit logging (query_id, actor, procedure, result count)

**Whitelisted Procedures** (add as you build):
```php
$allowed_procedures = [
    'sp_get_event_count_by_source',
    'sp_get_recent_telemetry',
    'sp_get_job_run_counts',
    'sp_get_recent_job_events',
    'sp_get_document_count',
    'sp_get_recent_documents',
    'sp_get_attestation_counts',
    'sp_get_recent_attestations',
    // Add more as built
];
```

### PowerShell Worker

**Location**: `AI_WORKERS/pwsh/cvi_worker.ps1`

**Purpose**: Invokes the PHP gateway with structured input and captures results.

**Usage**:
```powershell
.\cvi_worker.ps1 `
  -GatewayUrl "https://miratv.club/_workers/ai/cvi_gateway.php" `
  -Token "WORKER_TOKEN_HERE" `
  -Procedure "sp_get_event_count_by_source" `
  -Params @{ source = "ai_telemetry"; time_window_hours = 24 }
```

**Returns**:
```powershell
PSCustomObject {
  success = $true
  procedure = "sp_get_event_count_by_source"
  rows = @(PSCustomObject { source = "ai_telemetry"; event_count = 1542; ... })
  query_id = "550e8400-e29b-41d4-a716-446655440000"
}
```

**Error Handling**:
- ✅ HTTP failure → throw exception
- ✅ Timeout → return error object
- ✅ Token rejection → clear error message
- ✅ Retry logic (configurable attempts)

### Trigger System

**Location**: `AI_WORKERS/triggers/run_cvi_trigger.ps1`

**Purpose**: Entry point for queued query execution. Reads query payload from JSON file and invokes worker.

**Payload Format** (`queries/query_001.json`):
```json
{
  "query_id": "550e8400-e29b-41d4-a716-446655440000",
  "procedure": "sp_get_event_count_by_source",
  "params": {
    "source": "ai_telemetry",
    "time_window_hours": 24
  },
  "requested_by": "cortex_neuronet",
  "priority": "normal",
  "created_at": "2026-01-28T14:32:00Z"
}
```

**Invocation**:
```powershell
.\triggers/run_cvi_trigger.ps1 -QueryFile "queries/query_001.json"
```

**Execution**:
1. Load query JSON
2. Invoke `cvi_worker.ps1` with procedure + params
3. Capture result
4. Log to audit trail (`queries/results/query_001_result.json`)
5. Publish result to carousel (via `sp_cvi_publish`)

**Result Artifact** (`queries/results/query_001_result.json`):
```json
{
  "query_id": "550e8400-e29b-41d4-a716-446655440000",
  "procedure": "sp_get_event_count_by_source",
  "status": "success",
  "row_count": 1,
  "execution_time_ms": 245,
  "executed_at": "2026-01-28T14:35:22Z",
  "rows": [
    { "source": "ai_telemetry", "event_count": 1542, "latest_event": "2026-01-28T14:32:00Z" }
  ]
}
```

---

## How It Works: Step-by-Step

### Scenario: AI Agent Queries Component Health

**1. Agent (Cortex/GenAI) wants to know:**
```
"What is the error rate for series_normalize in the last 24 hours?"
```

**2. Agent creates trigger file** (`queries/query_health_001.json`):
```json
{
  "query_id": "abc123",
  "procedure": "sp_get_job_failure_rate",
  "params": { "job_key": "series_normalize", "time_window_hours": 24 },
  "requested_by": "ai_agent"
}
```

**3. Agent invokes trigger**:
```powershell
./triggers/run_cvi_trigger.ps1 -QueryFile "queries/query_health_001.json"
```

**4. Trigger → Worker → Gateway → Stored Procedure**:
- Worker calls `cvi_gateway.php` with token + procedure name
- Gateway validates token, checks whitelist
- Gateway executes: `CALL sp_get_job_failure_rate('series_normalize', 24)`

**5. Stored Procedure** (`sp_get_job_failure_rate`):
```sql
DECLARE @total_runs INT = (SELECT COUNT(*) FROM job_runs WHERE job_key = @job_key AND started_at > DATE_SUB(NOW(), INTERVAL @time_window_hours HOUR));
DECLARE @failed_runs INT = (SELECT COUNT(*) FROM job_runs WHERE job_key = @job_key AND status = 'failed' AND started_at > DATE_SUB(NOW(), INTERVAL @time_window_hours HOUR));

SELECT 
  job_key,
  total_runs AS @total_runs,
  failed_runs AS @failed_runs,
  ROUND((@failed_runs / @total_runs) * 100, 2) AS failure_rate_pct,
  NOW() AS computed_at;
```

**6. Result returned**:
```json
{
  "success": true,
  "rows": [
    { 
      "job_key": "series_normalize",
      "total_runs": 1250,
      "failed_runs": 18,
      "failure_rate_pct": 1.44,
      "computed_at": "2026-01-28T14:35:22Z"
    }
  ]
}
```

**7. Trigger logs result**:
- Saves to `queries/results/query_health_001_result.json`
- Publishes to `cvi_carousel` via `sp_cvi_publish('ops', 'query_result', {...})`

**8. Agent interprets result**:
```
Failure rate: 1.44% over last 24h
Confidence: High (1250 data points)
Status: NOMINAL (below 5% threshold)
```

---

## Building New Fact Procedures

### Pattern: Safe Read-Only Fact Query

**Template** (add to appropriate `*_basic_facts.sql`):

```sql
USE `target_database`;

DELIMITER //

-- Query: Get failure count by error type
-- Purpose: Surface error distribution for risk assessment
-- Output: error_type, count, recent_errors (sample)

CREATE PROCEDURE sp_get_failure_summary(
  IN p_time_window_hours INT DEFAULT 24
)
READS SQL DATA
COMMENT 'Return error distribution over time window'
BEGIN
  SELECT 
    error_type,
    COUNT(*) AS error_count,
    MAX(created_at) AS most_recent,
    GROUP_CONCAT(DISTINCT error_summary SEPARATOR '; ' ORDER BY error_summary LIMIT 3) AS sample_errors
  FROM job_failures
  WHERE created_at > DATE_SUB(NOW(), INTERVAL p_time_window_hours HOUR)
  GROUP BY error_type
  ORDER BY error_count DESC;
END //

DELIMITER ;
```

**Guidelines**:
- ✅ Name with `sp_get_*` prefix (facts only)
- ✅ Use `READS SQL DATA` (read-only)
- ✅ Accept time window as parameter
- ✅ Return timestamped results
- ✅ Add comment describing purpose
- ❌ No INSERT/UPDATE/DELETE
- ❌ No dynamic SQL
- ❌ No direct database writes

### Add to Whitelist

Update `cvi_gateway.php`:
```php
$allowed_procedures = [
    // ... existing ...
    'sp_get_failure_summary',
];
```

### Deploy

```bash
USE `xpdgxfsp_ops`;
SOURCE AI_WORKERS/sql/ops_basic_facts.sql;
```

---

## Configuration & Deployment Checklist

### Prerequisites
- [ ] MySQL user with EXECUTE on all target databases
- [ ] DSN (host, database, user, password) for each DB
- [ ] Worker token (any secure string; rotate regularly)
- [ ] Web server with PHP 7.4+ at `/_workers/ai/`

### Setup Steps

1. **Create CVI schema in each database**:
   ```bash
   for db in xpdgxfsp_content xpdgxfsp_ip xpdgxfsp_ops xpdgxfsp_lake_vector xpdgxfsp_i_m_g_vector_context xpdgxfsp_inhibitor_govenor_matrix xpdgxfsp_callosum_matrix; do
     mysql -h host -u user -p -e "USE \`$db\`; SOURCE AI_WORKERS/sql/cvi/create_cvi_${db}.sql"
   done
   ```

2. **Deploy basic fact procedures**:
   ```bash
   mysql -h host -u user -p xpdgxfsp_lake_vector < AI_WORKERS/sql/basic_facts.sql
   mysql -h host -u user -p xpdgxfsp_ops < AI_WORKERS/sql/ops_basic_facts.sql
   # ... repeat for each DB
   ```

3. **Copy PHP gateway to webroot**:
   ```bash
   cp AI_WORKERS/php/cvi_gateway.php /home/xpdgxfsp/public_html/_workers/ai/
   ```

4. **Update gateway configuration**:
   ```php
   // cvi_gateway.php (top of file)
   define('WORKER_TOKEN', 'your-secure-token-here');
   define('DB_HOST', 'localhost');
   define('DB_USER', 'miratv_readonly_cvi');
   define('DB_PASS', 'password');
   ```

5. **Test gateway**:
   ```powershell
   $result = Invoke-WebRequest -Uri "https://miratv.club/_workers/ai/cvi_gateway.php?token=your-secure-token-here" `
     -Method POST `
     -ContentType "application/json" `
     -Body '{"procedure":"sp_get_event_count_by_source","params":{"source":"ai_telemetry","time_window_hours":24}}'
   $result.Content | ConvertFrom-Json
   ```

6. **Grant database permissions**:
   ```sql
   CREATE USER 'miratv_readonly_cvi'@'localhost' IDENTIFIED BY 'password';
   GRANT EXECUTE ON xpdgxfsp_lake_vector.* TO 'miratv_readonly_cvi'@'localhost';
   GRANT EXECUTE ON xpdgxfsp_ops.* TO 'miratv_readonly_cvi'@'localhost';
   -- ... repeat for all DBs
   FLUSH PRIVILEGES;
   ```

7. **Test worker locally**:
   ```powershell
   .\AI_WORKERS/pwsh/cvi_worker.ps1 `
     -GatewayUrl "https://miratv.club/_workers/ai/cvi_gateway.php" `
     -Token "your-secure-token-here" `
     -Procedure "sp_get_event_count_by_source" `
     -Params @{ source = "ai_telemetry"; time_window_hours = 24 }
   ```

### Monitoring & Audit

**Query Audit Log** (logged to `cvi_gateway.php`):
```
[2026-01-28 14:35:22] QUERY_EXECUTED | query_id=abc123 | procedure=sp_get_event_count_by_source | actor=ai_agent | status=success | row_count=1 | exec_time_ms=245
```

**Check Results**:
```bash
# Recent query results
ls -la AI_WORKERS/triggers/queries/results/ | tail -10

# Check cvi_carousel publications
mysql -h host -u user -p -e "USE xpdgxfsp_ops; SELECT published_at, source_system, message_type, published_by FROM cvi_carousel ORDER BY published_at DESC LIMIT 20;"
```

---

## Future: Perspective Report Procedures

As the system matures, add higher-level procedures that compute perspectives:

```sql
-- Example (not yet implemented)
PROCEDURE sp_get_perspective_report(
  IN p_component VARCHAR,
  IN p_focus VARCHAR,           -- 'SYSTEM', 'RISK', 'KNOWLEDGE', 'PERFORMANCE', 'GOVERNANCE'
  IN p_time_window_hours INT,
  IN p_comparison_component VARCHAR -- optional
)
READS SQL DATA
```

This will aggregate deltas × foci to surface structured insights that AI can reason about directly.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Token rejected | Check token in `cvi_gateway.php` matches worker invocation |
| Procedure not found | Verify procedure name in whitelist; check it was deployed to correct DB |
| "Access denied" MySQL error | Verify user `miratv_readonly_cvi` has EXECUTE grant on target procedure |
| Timeout (30s exceeded) | Procedure is too slow; optimize query or add index |
| Empty result set | Check time window; verify data exists in source table |
| Gateway returns 404 | Confirm `cvi_gateway.php` is in webroot at `/_workers/ai/` |

---

## Next Steps

1. ✅ Deploy CVI schema + basic facts to all 7 DBs
2. ✅ Test gateway + worker locally
3. ⏳ Build per-DB domain-specific fact procedures (e.g., `sp_get_series_ingest_status()`)
4. ⏳ Implement delta computation procedures (semantic, statistical, structural)
5. ⏳ Add perspective report aggregators (SYSTEM, RISK, KNOWLEDGE, PERFORMANCE, GOVERNANCE)
6. ⏳ Wire GenAI agent to query gateway

---

## Status

**Current Phase**: Basic fact queries + CVI carousel infrastructure
**Owner**: Architecture
**Last Updated**: 2026-01-28