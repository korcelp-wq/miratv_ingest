# MiraTV Ingest — P0 DB-Backed Worker Baseline

Date: 2026-05-27  
Repository: `miratv_ingest`  
Branch: `main`  
Baseline status: **P0 DB-backed worker baseline complete**

## Summary

This baseline moves the P0 worker scaffold from local/dry-run validation into read-only DB-backed operational checks through `tools/common/DbQuery.psm1` and `dog_open_proc.php`.

The completed worker set now provides observable runtime signals for:

- worker heartbeat health
- automation contract compliance
- user/bouquet/item/series availability scaffolds
- EPG freshness
- EPG join correctness
- cache stale-serving health
- live DB quality gates
- materialization queue health
- playback preflight attribution coverage

All DB-backed worker checks are read-only. No worker in this baseline mutates source tables.

## Current contract status

Latest confirmed contract checker result:

```text
RESULT: pass total_units=11 compliant=11 blocked=0
```

This means all registered automation units currently satisfy the contract gates:

1. The worker exists.
2. The worker logs.
3. The worker emits heartbeat where required.
4. Required signals exist in the worker source.
5. Required signals are present in the signal dictionary.
6. Required signals are present in the dashboard mapping.
7. Required kill switch is present.

## Latest commit stack

```text
3546d69 feat: add DB mode to playback preflight attribution worker
1b7534e feat: add DB mode to materialization queue worker
e32ab89 fix: align cache stale-serving contract signals
fd0a03d feat: add adaptive DB mode to cache stale-serving worker
ff97b29 fix: treat global live channel variants as non-actionable duplicates
5935eef feat: add DB mode to live quality gates worker
1397c3b fix: exclude non-actionable EPG legacy join noise
d23f5a3 feat: add DB mode to EPG join validation worker
b48c6f4 feat: add dog_open_proc DB query helper and EPG freshness DB mode
7c280d7 docs: update README for completed P0 scaffold baseline
```

## Worker inventory

| Worker | Path | Current DB mode status | Notes |
|---|---|---:|---|
| Worker heartbeat emitter | `tools/workers/emit_worker_heartbeat.ps1` | scaffold | Emits runtime heartbeat signals. |
| Automation contract checker | `tools/workers/check_automation_contract_status.ps1` | pass | Confirms 11/11 workers compliant. |
| User bouquet availability | `tools/workers/refresh_user_bouquet_availability.ps1` | scaffold | Availability refresh scaffold remains contract-compliant. |
| User item availability | `tools/workers/refresh_user_item_availability.ps1` | scaffold | Availability item scaffold remains contract-compliant. |
| User series availability | `tools/workers/refresh_user_series_availability.ps1` | scaffold | Series availability scaffold remains contract-compliant. |
| EPG freshness | `tools/workers/check_epg_freshness.ps1` | working | Reads EPG state through DbQuery. Current warning is a real stale EPG signal. |
| EPG join validation | `tools/workers/check_epg_join_validation.ps1` | working | Preferred join is healthy; raw bad legacy rows are split into actionable/excluded. |
| Cache stale-serving | `tools/workers/check_cache_stale_serving.ps1` | working | Adaptive table/column discovery; stale-serving currently passes. |
| DB quality gates | `tools/workers/run_db_quality_gates.ps1` | working | Live quality gates pass after raw/actionable duplicate split. |
| Materialization queue | `tools/workers/check_materialization_queue.ps1` | working | Reads queue from `ip` DB; current warning is a real queue backlog/retry signal. |
| Playback preflight attribution | `tools/workers/check_playback_preflight_attribution.ps1` | working | Provider attribution coverage is 100%; missing container metadata remains visible. |

## DB query helper

Shared helper:

```text
tools/common/DbQuery.psm1
```

Purpose:

- centralizes read-only query execution through `dog_open_proc.php`
- enforces read-only SQL starts
- blocks mutation commands
- supports multiple database keys through the backend bridge
- keeps worker logic local-first and safe

Read-only SQL commands allowed by the helper include:

```text
SELECT
SHOW
DESCRIBE / DESC
EXPLAIN
WITH
```

Mutation commands remain blocked.

## Required environment variables

For DbQuery mode:

```powershell
$env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
$env:DOG_OPEN_PROC_TOKEN = "<token>"
```

## Standard validation commands

Run from repository root:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_automation_contract_status.ps1" -Environment "dev"
```

Expected contract result:

```text
RESULT: pass total_units=11 compliant=11 blocked=0
```

## Current operational findings

### EPG freshness

Status: **warning, real operational signal**

The EPG freshness worker can query the DB successfully. The warning indicates the EPG dataset is stale, not that the worker is broken.

Current interpretation:

```text
DB mode works.
Program count is available.
Freshness age is above the configured threshold.
Next action is EPG refresh/import validation, not worker repair.
```

### EPG join validation

Status: **pass**

Correct join rule:

```sql
epg_programs.epg_channel_id = live_channels.epg_channel_id
```

Acceptable fallback:

```sql
epg_programs.channel = live_channels.epg_channel_id
```

Bad legacy join to avoid:

```sql
live_channels.id = epg_programs.channel
```

The worker now separates:

```text
bad_legacy_join_rows_raw
bad_legacy_join_rows_excluded
bad_legacy_join_rows_actionable
```

Current interpretation:

```text
Preferred join is healthy.
Raw legacy collision rows exist.
All observed raw legacy rows are non-actionable noise after exclusion.
```

### Live DB quality gates

Status: **pass**

The live quality worker now treats global channel-brand duplicates correctly.

The worker separates:

```text
duplicate_rows_raw
duplicate_rows_variant
duplicate_rows_actionable
duplicate_ratio_raw
duplicate_ratio_actionable
```

Current interpretation:

```text
Raw duplicate brand rows exist.
Many are valid country/language/category/provider variants.
Actionable duplicate ratio is low enough to pass.
Blank key ratio is clean.
Filter diversity is healthy.
```

### Cache stale-serving

Status: **pass**

The cache worker now uses adaptive table/column discovery rather than assuming every cache table has the same timestamp/status columns.

Current confirmed shape:

```text
status=ok
result=pass
served_from=cache_stale_refreshing
cache_scope=known_app_caches
total_rows=52479
stale_ratio=0.025000
refresh_needed_rows=3
```

Current interpretation:

```text
Cache stale-serving is healthy.
Some stale rows exist.
Stale-serving fallback is working.
A small number of cache areas need refresh attention.
```

### Materialization queue

Status: **warning, real operational signal**

The queue exists in the `ip` DB:

```text
DatabaseKey = ip
Table = content_materialization_queue
```

Current confirmed shape:

```text
queue_table=content_materialization_queue
pending_count=459
oldest_age_minutes=24821
dead_letter_count=0
requeue_rate=0.952631
```

Current interpretation:

```text
The worker is correct.
The materialization queue has a real backlog/retry problem.
No dead-letter problem is visible yet.
Old pending items and high requeue rate indicate consumers are not keeping up or are repeatedly reprocessing items.
```

### Playback preflight attribution

Status: **pass**

Current confirmed shape:

```text
coverage_percent=100.000
total_candidates=233207
unattributed_count=0
missing_provider_id_count=0
missing_container_count=195611
blocked_406_count=0
```

Current interpretation:

```text
Provider attribution is complete.
Every playback candidate can be tied back to provider identity.
Container metadata is still incomplete.
Missing container data remains a playback resolver follow-up, especially for VOD/Series.
```

## Signal dictionary and dashboard mapping alignment

The cache stale-serving worker now emits:

```text
cache_stale_serving_status
cache_stale_ratio
worker_heartbeat_status
```

The contract checker, signal dictionary, and dashboard mapping were aligned so these names replace the older cache signal names:

```text
cache_served_from
stale_ratio_by_screen
```

This alignment restored:

```text
RESULT: pass total_units=11 compliant=11 blocked=0
```

## Runtime artifacts

The `runtime/` directory contains generated local logs and diagnostics. It is ignored by Git and should not be committed.

Confirmed ignored path:

```text
runtime/
```

Safe cleanup command:

```powershell
Remove-Item ".\runtime" -Recurse -Force
```

## Important architectural decisions captured

### Read-only DB mode first

All new DB-backed modes are read-only. They inspect operational state but do not mutate source tables.

### Raw vs actionable signals

The baseline avoids false alarms by splitting raw observations from actionable faults.

Examples:

```text
EPG legacy join:
- raw
- excluded
- actionable

Live duplicates:
- raw
- variant
- actionable

Cache stale-serving:
- active
- stale
- serveable stale
- expired

Playback preflight:
- provider attribution
- container availability
```

### Global live inventory, not only the Live screen

EPG and live quality checks operate over base `live_channels`, not only the UI screen called `Live`.

This matters because EPG applies to all live-derived surfaces:

```text
Live
24/7
PPV
Soccer
APS
Home live shelves
```

### Materialization queue lives in the IP database

The queue worker defaults to:

```powershell
[string]$DatabaseKey = "ip"
```

because the table is:

```text
xpdgxfsp_ip.content_materialization_queue
```

not:

```text
xpdgxfsp_content.content_materialization_queue
```

## Recommended next steps

### 1. Investigate materialization queue backlog

Focus on:

```text
pending_count=459
oldest_age_minutes=24821
requeue_rate=0.952631
```

Recommended diagnostic questions:

```text
Which content_type values are stuck?
Which materialization_kind values are retrying?
Which trigger_reason values dominate?
Which rows have highest attempts?
Are consumers running?
Are consumers failing silently?
Are consumers requeueing rows without completing them?
```

### 2. Inspect missing container metadata

Playback attribution is clean, but container metadata is incomplete.

Recommended diagnostic questions:

```text
How much of missing_container_count is Live vs VOD vs Series?
Are VOD rows missing provider container_extension?
Do Series episodes have provider episode container metadata?
Should container resolution be deferred to playback time through provider get_vod_info/get_series_info?
```

### 3. Refresh stale EPG

The EPG freshness warning is real. The next action is not to repair the worker; it is to validate/import fresh EPG data and confirm the freshness worker returns pass or acceptable warning.

### 4. Keep contract checker strict

The contract checker should remain strict because it caught a real naming mismatch between the worker, signal dictionary, and dashboard mapping.

## Commit checklist for future worker changes

Before committing any worker change:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<worker_path>" -Environment "dev"

pwsh -NoProfile -ExecutionPolicy Bypass -File "<worker_path>" -Environment "dev" -Mode "DbQuery"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_automation_contract_status.ps1" -Environment "dev"

git status --short
```

Commit only after:

```text
worker DryRun works
worker DbQuery works
contract checker passes
git status shows only intended file changes
runtime/ is not staged
```

## Baseline conclusion

The P0 automation layer is now a working read-only operational telemetry baseline.

It does not yet fix every operational problem, but it now makes the problems visible:

```text
EPG is stale.
Materialization queue is backed up/retrying.
Playback provider attribution is complete.
Container metadata still needs resolver work.
Cache stale-serving is healthy.
Live quality gates are stable when raw variants are separated from actionable faults.
```

This is the intended P0 outcome: move from assumptions and scattered diagnostics to repeatable, contract-checked, DB-backed operational signals.
