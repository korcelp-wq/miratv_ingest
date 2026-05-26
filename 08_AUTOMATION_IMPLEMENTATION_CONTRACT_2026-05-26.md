# Automation Implementation Contract (2026-05-26)

Status: Approved implementation contract.

## Governance Loop (Hard Gate)
No automation is complete until all five conditions are true:
1. It logs.
2. It heartbeats if recurring.
3. It emits one named signal.
4. That signal appears in dashboard mapping.
5. It has rollback/kill switch.

## Applies To
- All recreated or modified components in ingest automation scope.
- Paths include `C:\miraTV_ingest` and `C:\miratv_ingest` surfaces (`_workers`, `_ingest`, `tools`, `triggers`, queue/materialization/cache workers).

## Definition Of Done (Per Automation Unit)
Recurring workers must update heartbeat before work starts, during long-running work, and at terminal state.
A unit cannot be marked done unless all checks pass:
- `LOGGING_ENABLED`: Structured logs emitted for `job_started`, `job_completed`, `job_failed` at minimum.
- `HEARTBEAT_ENABLED`: Required for recurring workers; heartbeat interval and stale threshold defined.
- `SIGNAL_EMITTED`: At least one signal from `07_P0_SIGNAL_DICTIONARY_2026-05-26.csv` emitted with valid values.
- `DASHBOARD_MAPPED`: Signal exists in `10_DASHBOARD_SIGNAL_MAPPING_2026-05-26.csv` with panel and alert owner.
- `KILL_SWITCH_DEFINED`: Unit has disable path (env/config flag or DB switch) and rollback command documented.

## Required Runtime Controls
Each recurring unit must define:
- `component_name`
- `run_id`
- `enabled_flag` (kill switch)
- `heartbeat_interval_seconds`
- `stale_after_seconds`
- `max_retry_attempts`
- `backoff_seconds`

## Minimum Structured Log Payload
Required fields per record:
- `job_name`
- `run_id`
- `worker_name`
- `component`
- `environment`
- `database_target`
- `source_name`
- `started_at`
- `ended_at`
- `status`
- `attempt`
- `error_code`
- `error_message`

Conditional fields:
- `mac_user_id` when user-scoped
- `screen_type` when screen-scoped

## Secret Redaction Rule
Never log raw values for:
- `provider_username`
- `provider_password`
- `token`
- `api_key`
- full playback URLs

Allowed format: `REDACTED` or one-way hash.

## Contracted Function Calls (Implementation-Level)
PowerShell units should implement at least:
- `Write-JobLog`
- `Emit-Heartbeat`
- `Emit-Signal`
- `Test-KillSwitch`

PHP units should implement at least:
- `worker_log(...)`
- `emit_heartbeat(...)`
- `emit_signal(...)`
- `is_kill_switch_enabled(...)`

## Validation Commands (Pre-Deploy)
Run and archive outputs before enabling a unit:
1. Logging check: sample run shows `job_started` and terminal state (`job_completed` or `job_failed`).
2. Heartbeat check: heartbeat updates at configured cadence.
3. Signal check: signal row appears in signal events store.
4. Dashboard check: mapped panel displays latest value.
5. Kill switch check: disable flag stops execution within one cycle.

## Non-Compliance Action
If any gate fails:
- Unit status = `blocked`
- Deploy/restart denied
- Owner receives action item with missing gate names
