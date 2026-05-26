CVI (Callosum Vector Integration) — README

Overview

This folder provides the minimal artifacts to publish and consume small, auditable messages (the "carousel") across MiraTV databases. It is intentionally conservative: publishes are done via stored procedures and queued consumers; read-only facts live in each source DB.

Key components

- `cvi_carousel` table (per-database)
  - Columns: `id`, `component`, `payload_type`, `payload` (JSON), `source_actor`, `source_system`, `signature`, `created_at`, `processed`, `processed_at`.
  - Purpose: append-only queue for cross-component documents/messages.

- `sp_cvi_publish` stored procedure (per-database)
  - Minimal publisher: inserts a JSON payload and returns `inserted_id`.
  - Location: `AI_WORKERS/sql/cvi/create_cvi_<dbname>.sql` (one script per DB).

- Basic-facts stored procedures
  - Safe read-only procedures that expose domain facts from the DB where the data lives (examples in `AI_WORKERS/sql` and `AI_WORKERS/sql/cvi`).
  - Telemetry facts intended for `xpdgxfsp_ops`.

- Gateway: `AI_WORKERS/php/cvi_gateway.php`
  - Token-authenticated (HTTP header `X-CVI-TOKEN`).
  - Whitelisted procs only (`allowed_procs` array).
  - Returns all result sets as JSON.
  - Configure via environment: set `CVI_GATEWAY_TOKEN` and update DSN/DB credentials.

- Worker: `AI_WORKERS/pwsh/cvi_worker.ps1`
  - PowerShell example that calls the gateway with a procedure and parameters.
  - `AI_WORKERS/triggers/run_cvi_trigger.ps1` shows simple trigger usage reading a JSON payload.

Existing callosum support

- `xpdgxfsp_callosum_matrix` already contains `cm_documents`, `vw_cm_documents_read`, and `sp_cm_insert_document`. Use these for canonical callosum documents.

Deployment guide (per-database)

1. Review script and run in target DB. Example (MySQL CLI):

```sql
USE `xpdgxfsp_lake_vector`;
SOURCE /path/to/AI_WORKERS/sql/perspective_procs.sql;
```

Or, for a per-DB CVI file:

```sql
USE `xpdgxfsp_content`;
SOURCE /path/to/AI_WORKERS/sql/cvi/create_cvi_xpdgxfsp_content.sql;
```

2. Create DB roles/users with minimal privileges (example):
- `cvi_writer` : `EXECUTE` on `sp_cvi_publish` and `INSERT` on `cvi_carousel` as needed.
- `cvi_reader` : `SELECT` on `vw_cm_documents_read` or other read views.

3. Gateway deployment
- Place `AI_WORKERS/php/cvi_gateway.php` in a protected webroot (behind TLS).
- Set environment variable `CVI_GATEWAY_TOKEN` to a strong secret.
- Use a low-privilege DB account (only `EXECUTE` on allowed procs).

4. Worker/Trigger
- Deploy `AI_WORKERS/pwsh/cvi_worker.ps1` on an Ops host with `CVI_GATEWAY_TOKEN` in environment.
- Trigger scripts (e.g., scheduled, file-based, or webhook-driven) should validate payloads and call the worker.

Testing examples

- Curl test (gateway):

```bash
curl -X POST https://yourhost/AI_WORKERS/php/cvi_gateway.php \
  -H "X-CVI-TOKEN: $CVI_GATEWAY_TOKEN" \
  -d '{"proc":"sp_get_event_count_by_source","params":["series_normalize","2026-01-27 00:00:00","2026-01-28 00:00:00"]}'
```

- PowerShell worker test:

```powershell
$env:CVI_GATEWAY_TOKEN = 'your_token'
.
"./AI_WORKERS/pwsh/cvi_worker.ps1" -GatewayUrl 'https://yourhost/AI_WORKERS/php/cvi_gateway.php' -Proc 'sp_get_event_count_by_source' -Scope 'series_normalize' -Focus 'performance' -Start '2026-01-27 00:00:00' -End '2026-01-28 00:00:00'
```

Security & hardening recommendations

- Signature verification: `sp_cvi_publish` accepts an optional `signature` field. Implement verification in the gateway/worker (HMAC or PKI) before calling the proc.
- Auditing: log each publish request (gateway-level file log or central `cvi_events` audit table in a central ops DB). Consider inserting an audit row before calling `sp_cvi_publish` so writes are auditable even if downstream consumers fail.
- Idempotency: include `signature` or external `message_id` in `payload` to allow deduplication by consumers.
- Rate limits and throttling: protect the gateway with application-level rate limits and WAF rules.
- Principle of least privilege: DB accounts used by the gateway/worker should have only the rights needed.

Consumer pattern

- Consumers poll `cvi_carousel` by `processed=0` (or use DB notification where available).
- Validate and process JSON `payload` payload_type, then mark `processed=1` and set `processed_at`.
- Consumers should be idempotent and resilient to partial failures.

Operational notes

- Keep `sp_cm_insert_document` as the canonical document publisher for `xpdgxfsp_callosum_matrix`.
- Use per-DB `sp_cvi_publish` where local context is required; cross-DB coordination should be mediated by `xpdgxfsp_callosum_matrix` or via secure, audited transfers.

Files in this workspace

- `AI_WORKERS/sql/cvi/` — CVI table + `sp_cvi_publish` scripts per DB and basic-facts templates.
- `AI_WORKERS/sql/` — basic facts and perspective example stored procedures.
- `AI_WORKERS/php/cvi_gateway.php` — gateway.
- `AI_WORKERS/pwsh/cvi_worker.ps1` — worker.
- `AI_WORKERS/triggers/run_cvi_trigger.ps1` — trigger example.
- `AI_WORKERS/README.md` — quicknotes (summary changed to include CVI scripts).
- `AI_WORKERS/CVI_README.md` — this file (detailed CVI description).

If you'd like, I can now:
- (A) add an example `cvi_events` audit table and an audit-insert step to the gateway, or
- (B) implement a worker that verifies signatures and enqueues writes for the callosum DB.

Which should I do next?