# MiraTV Ingest Automation

Status: P0 scaffold baseline complete

This repository is the clean automation-governance baseline for MiraTV ingest, worker, signal, heartbeat, logging, and remediation automation.

The purpose of this repo is not to preserve the old raw ingest dump. The old working folder remains local/archive-only. This repo should contain only controlled, reviewed, contract-compliant automation assets.

---

## Current Repo Purpose

This repo exists to support safe automation of MiraTV backend data freshness and operational visibility.

It is responsible for:

- P0 remediation planning
- signal dictionary and dashboard mapping
- signal / heartbeat persistence schema contracts
- shared logging helpers
- worker heartbeat baseline
- automation contract validation
- availability refresh scaffolding
- EPG freshness and join validation scaffolding
- cache stale-serving visibility
- DB quality gate visibility
- materialization queue reliability visibility
- playback preflight attribution visibility
- future controlled worker migration from scaffold to DB-backed execution

It should not contain:

- provider credentials
- passwords
- API keys
- tokens
- full playback URLs
- raw EPG payloads
- large provider JSON dumps
- runtime logs
- old bulk ingest folders
- unreviewed legacy scripts

---

## Current Artifact Set

### Governance and remediation

```text
05_P0_REMEDIATION_BACKLOG_RANKED_2026-05-26.md
07_P0_SIGNAL_DICTIONARY_2026-05-26.csv
08_AUTOMATION_IMPLEMENTATION_CONTRACT_2026-05-26.md
09_SIGNAL_AND_HEARTBEAT_SCHEMA_CONTRACT_2026-05-26.sql
10_DASHBOARD_SIGNAL_MAPPING_2026-05-26.csv
```

### Shared helpers

```text
tools/common/Logging.psm1
_workers/common/worker_logging.php
```

### Current workers

```text
tools/workers/emit_worker_heartbeat.ps1
tools/workers/check_automation_contract_status.ps1
tools/workers/refresh_user_bouquet_availability.ps1
tools/workers/refresh_user_item_availability.ps1
tools/workers/refresh_user_series_availability.ps1
tools/workers/check_epg_freshness.ps1
tools/workers/check_epg_join_validation.ps1
tools/workers/check_cache_stale_serving.ps1
tools/workers/run_db_quality_gates.ps1
tools/workers/check_materialization_queue.ps1
tools/workers/check_playback_preflight_attribution.ps1
```

---

## Governance Loop

No automation is complete until all five conditions are true:

```text
1. It logs.
2. It heartbeats if recurring.
3. It emits one named signal.
4. That signal appears in dashboard mapping.
5. It has rollback / kill switch.
```

This rule applies to all recreated or modified ingest, batch, worker, queue, cache, materializer, repair, and diagnostic components.

---

## Operating Principles

The following rules must be preserved:

```text
Do not hard-delete provider/user availability data.
Mark stale/unavailable instead.
Keep known-good cache available during refresh failures.
Treat failure as signal.
Make workers observable before trusting automation.
No broad refactors.
One worker at a time.
No README churn during intermediate worker commits.
```

---

## Logging Requirement

All recreated or modified batch, ingest, worker, materializer, and repair components must include structured logging.

Implementation gate:

```text
No recreated ingest/batch/worker file is accepted unless it includes structured logging and heartbeat compatibility.
A component is not implementation-complete unless its logs support dashboard visibility and failure diagnosis.
```

Minimum required events:

```text
job_started
job_progress
job_completed
job_failed
heartbeat
checkpoint_saved
source_row_count
rows_inserted
rows_updated
rows_skipped
rows_failed
duration_ms
```

Minimum required fields per record:

```text
job_name
run_id
worker_name
component
environment
database_target
source_name
mac_user_id, if user-scoped
screen_type, if screen-scoped
started_at
ended_at
status
attempt
error_code
error_message
```

Sensitive values must be redacted:

```text
provider_username = REDACTED
provider_password = REDACTED
token = REDACTED
api_key = REDACTED
full_playback_url = REDACTED or hashed
```

---

## Local Working Path

Use the clean repo path for all future work:

```text
C:\miraTV_ingest_clean
```

The old folder is archive-only:

```text
C:\miraTV_ingest
```

Do not point Copilot, Dory, DeepSeek, or other automated editing agents at the old folder for active implementation work.

---

## PowerShell Version

Preferred runtime:

```text
pwsh
```

Legacy Windows PowerShell may work, but the clean workers should be validated with PowerShell 7+ when possible.

Check version:

```powershell
pwsh -v
```

---

## Current Worker Commands

Run all commands from repo root:

```powershell
cd C:\miraTV_ingest_clean
```

### 1. Emit worker heartbeat

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/emit_worker_heartbeat.ps1" -Environment "dev"
```

Expected result:

```text
OK: heartbeat emitted.
```

Signals:

```text
worker_heartbeat_status
last_heartbeat_at
```

Kill switch:

```text
ENABLE_WORKER_RUNTIME
```

---

### 2. Run automation contract checker

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_automation_contract_status.ps1" -Environment "dev"
```

Expected result:

```text
RESULT: pass total_units=11 compliant=11 blocked=0
```

Current units checked:

```text
emit_worker_heartbeat
check_automation_contract_status
refresh_user_bouquet_availability
refresh_user_item_availability
refresh_user_series_availability
check_epg_freshness
check_epg_join_validation
check_cache_stale_serving
run_db_quality_gates
check_materialization_queue
check_playback_preflight_attribution
```

---

### 3. Run bouquet availability scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_bouquet_availability.ps1" -Environment "dev"
```

Expected result:

```text
OK: availability refresh scaffold completed.
```

Signals:

```text
availability_refresh_status
availability_refresh_lag_minutes
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_AVAILABILITY_REFRESH
```

---

### 4. Run item availability scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_item_availability.ps1" -Environment "dev"
```

Expected result:

```text
OK: item availability refresh scaffold completed.
```

Signals:

```text
availability_refresh_status
availability_refresh_lag_minutes
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_AVAILABILITY_REFRESH
```

---

### 5. Run series availability scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_series_availability.ps1" -Environment "dev"
```

Expected result:

```text
OK: series availability refresh scaffold completed.
```

Signals:

```text
availability_refresh_status
availability_refresh_lag_minutes
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_AVAILABILITY_REFRESH
```

---

### 6. Run EPG freshness scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" -Environment "dev"
```

Expected result:

```text
OK: EPG freshness check completed.
```

Signals:

```text
epg_freshness_age_hours
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_EPG_IMPORT
```

---

### 7. Run EPG join validation scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" -Environment "dev"
```

Expected result:

```text
OK: EPG join validation completed.
```

Signals:

```text
epg_join_validation_status
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_EPG_JOIN_GATE
```

Join rules:

```text
Preferred:
epg_programs.epg_channel_id = live_channels.epg_channel_id

Acceptable fallback:
epg_programs.channel = live_channels.epg_channel_id

Prohibited legacy join:
live_channels.id = epg_programs.channel
```

---

### 8. Run cache stale-serving scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" -Environment "dev"
```

Expected result:

```text
OK: cache stale-serving check completed.
```

Signals:

```text
cache_served_from
stale_ratio_by_screen
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_ASYNC_CACHE_REFRESH
```

---

### 9. Run DB quality gates scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" -Environment "dev"
```

Expected result:

```text
OK: DB quality gates completed.
```

Signals:

```text
quality_gate_result
duplicate_ratio
blank_key_ratio
filter_diversity_score
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_DB_QUALITY_GATE_AUTOMATION
```

---

### 10. Run materialization queue scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" -Environment "dev"
```

Expected result:

```text
OK: materialization queue check completed.
```

Signals:

```text
materialization_queue_oldest_age_minutes
materialization_dead_letter_count
materialization_requeue_rate
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_MATERIALIZATION_CONSUMERS
```

---

### 11. Run playback preflight attribution scaffold

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" -Environment "dev"
```

Expected result:

```text
OK: playback preflight attribution check completed.
```

Signals:

```text
playback_preflight_outcome
attribution_coverage_percent
worker_heartbeat_status
```

Kill switch:

```text
ENABLE_PLAYBACK_ATTRIBUTION
```

Outcome values tracked:

```text
playable
unavailable
stale_id
bouquet_denied
provider_error
container_unsupported
resolver_error
unknown
disabled
dry_run
failed
```

---

## Kill Switch Examples

### Disable worker runtime

```powershell
$env:ENABLE_WORKER_RUNTIME = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/emit_worker_heartbeat.ps1" -Environment "dev"
$env:ENABLE_WORKER_RUNTIME = $null
```

Expected result:

```text
SKIPPED: ENABLE_WORKER_RUNTIME is disabled.
```

### Disable availability refresh workers

```powershell
$env:ENABLE_AVAILABILITY_REFRESH = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_bouquet_availability.ps1" -Environment "dev"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_item_availability.ps1" -Environment "dev"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_series_availability.ps1" -Environment "dev"
$env:ENABLE_AVAILABILITY_REFRESH = $null
```

Expected result:

```text
SKIPPED: ENABLE_AVAILABILITY_REFRESH is disabled.
```

### Disable EPG workers

```powershell
$env:ENABLE_EPG_IMPORT = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" -Environment "dev"
$env:ENABLE_EPG_IMPORT = $null

$env:ENABLE_EPG_JOIN_GATE = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" -Environment "dev"
$env:ENABLE_EPG_JOIN_GATE = $null
```

### Disable cache worker

```powershell
$env:ENABLE_ASYNC_CACHE_REFRESH = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" -Environment "dev"
$env:ENABLE_ASYNC_CACHE_REFRESH = $null
```

### Disable DB quality gates

```powershell
$env:ENABLE_DB_QUALITY_GATE_AUTOMATION = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" -Environment "dev"
$env:ENABLE_DB_QUALITY_GATE_AUTOMATION = $null
```

### Disable materialization consumers

```powershell
$env:ENABLE_MATERIALIZATION_CONSUMERS = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" -Environment "dev"
$env:ENABLE_MATERIALIZATION_CONSUMERS = $null
```

### Disable playback attribution

```powershell
$env:ENABLE_PLAYBACK_ATTRIBUTION = "false"
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" -Environment "dev"
$env:ENABLE_PLAYBACK_ATTRIBUTION = $null
```

---

## Runtime Logs

Local-first JSONL logs are written under:

```text
runtime/logs/
```

Example worker log folders:

```text
runtime/logs/worker_runtime/
runtime/logs/automation_contract_checker/
runtime/logs/availability_worker/
runtime/logs/availability_item_worker/
runtime/logs/availability_series_worker/
runtime/logs/epg_import_worker/
runtime/logs/epg_validation_gate/
runtime/logs/cache_reader/
runtime/logs/db_quality_gate/
runtime/logs/materialization_queue_worker/
runtime/logs/playback_resolver/
```

Runtime logs are intentionally ignored by Git and should not be committed.

---

## Current Validation State

Last known validation state:

```text
emit_worker_heartbeat                         PASS
check_automation_contract_status              PASS
refresh_user_bouquet_availability             PASS / DryRun
refresh_user_item_availability                PASS / DryRun
refresh_user_series_availability              PASS / DryRun
check_epg_freshness                           PASS / DryRun
check_epg_join_validation                     PASS / DryRun
check_cache_stale_serving                     PASS / DryRun
run_db_quality_gates                          PASS / DryRun
check_materialization_queue                   PASS / DryRun
check_playback_preflight_attribution          PASS / DryRun

contract checker                              RESULT: pass total_units=11 compliant=11 blocked=0
```

The PowerShell warning about unapproved verbs from the `Logging` module is currently accepted as non-blocking.

---

## Git Rules

Before staging:

```powershell
git status --short
```

Before committing:

```powershell
git diff --cached --name-only
```

Do not stage:

```text
runtime/
logs/
raw payloads
provider dumps
secrets
tokens
.env files
old ingest archive folders
```

Commit pattern:

```powershell
git add <reviewed files only>
git status --short
git commit -m "<type>: <clear message>"
git push
```

---

## Current Commit Baseline

Current known clean history after P0 scaffold completion:

```text
dd7c908 feat: add playback preflight attribution scaffold
a05bcf7 feat: add materialization queue reliability scaffold
dab6b97 feat: add DB quality gates scaffold
e45a160 feat: add cache stale-serving check scaffold
dd98c5c chore: restore contract checker and include EPG join validation
807c1ba feat: add EPG join validation scaffold
760f363 feat: add EPG freshness check scaffold
9b1f01c feat: add user series availability scaffold
65f2852 feat: add user item availability scaffold
02384d2 feat: add automation contract checker and availability scaffold
```

---

## Next Development Phase

The P0 scaffold set is complete. Next work should convert scaffolds into real implementation in controlled order.

Recommended order:

```text
1. Add DB/query bridge read mode for EPG freshness.
2. Add DB/query bridge read mode for EPG join validation.
3. Add DB/query bridge read mode for cache stale-serving.
4. Add DB/query bridge read mode for DB quality gates.
5. Add DB/query bridge read mode for materialization queue reliability.
6. Add DB/query bridge read mode for availability workers.
7. Add playback attribution read/write implementation after resolver source of truth is stable.
```

Do not jump directly into DB mutation. Prefer read-only validation first, then controlled writes only after each worker emits correct logs/signals.

---

## Development Discipline

Use this repo as a controlled implementation lane.

Rules:

```text
One worker at a time.
One commit per clean unit.
No broad refactors.
No unreviewed legacy import.
No raw old ingest dump.
No secrets.
No runtime logs.
No worker accepted without logs, heartbeat/signals, dashboard mapping, and kill switch.
README updates can be batched at phase boundaries instead of every worker.
```

Badaboom.
