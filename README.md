# MiraTV Ingest Automation

Status: MVP backend / automation hardening track

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
- future controlled worker migration

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
Shared helpers
tools/common/Logging.psm1
_workers/common/worker_logging.php
Current workers
tools/workers/emit_worker_heartbeat.ps1
tools/workers/check_automation_contract_status.ps1
tools/workers/refresh_user_bouquet_availability.ps1
tools/workers/refresh_user_item_availability.ps1
Governance Loop

No automation is complete until all five conditions are true:

1. It logs.
2. It heartbeats if recurring.
3. It emits one named signal.
4. That signal appears in dashboard mapping.
5. It has rollback / kill switch.

This rule applies to all recreated or modified ingest, batch, worker, queue, cache, materializer, repair, and diagnostic components.

Operating Principles

The following rules must be preserved:

Do not hard-delete provider/user availability data.
Mark stale/unavailable instead.
Keep known-good cache available during refresh failures.
Treat failure as signal.
Make workers observable before trusting automation.
Logging Requirement

All recreated or modified batch, ingest, worker, materializer, and repair components must include structured logging.

Implementation gate:

No recreated ingest/batch/worker file is accepted unless it includes structured logging and heartbeat compatibility.
A component is not implementation-complete unless its logs support dashboard visibility and failure diagnosis.

Minimum required events:

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

Minimum required fields per record:

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

Sensitive values must be redacted:

provider_username = REDACTED
provider_password = REDACTED
token = REDACTED
api_key = REDACTED
full_playback_url = REDACTED or hashed
Local Working Path

Use the clean repo path for all future work:

C:\miraTV_ingest_clean

The old folder is archive-only:

C:\miraTV_ingest

Do not point Copilot, Dory, DeepSeek, or other automated editing agents at the old folder for active implementation work.

PowerShell Version

Preferred runtime:

pwsh

Legacy Windows PowerShell may work, but the clean workers should be validated with PowerShell 7+ when possible.

Check version:

pwsh -v
Current Worker Commands

Run all commands from repo root:

cd C:\miraTV_ingest_clean
1. Emit worker heartbeat
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/emit_worker_heartbeat.ps1" -Environment "dev"

Expected result:

OK: heartbeat emitted.

This worker emits:

worker_heartbeat_status
last_heartbeat_at

Kill switch:

ENABLE_WORKER_RUNTIME
2. Run automation contract checker
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_automation_contract_status.ps1" -Environment "dev"

Expected result:

RESULT: pass total_units=4 compliant=4 blocked=0

This validates the current automation units against the implementation contract.

Current units checked:

emit_worker_heartbeat
check_automation_contract_status
refresh_user_bouquet_availability
refresh_user_item_availability
3. Run bouquet availability scaffold
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_bouquet_availability.ps1" -Environment "dev"

Expected result:

OK: availability refresh scaffold completed.

Current mode:

DryRun

This scaffold does not write to the database yet. It proves logging, heartbeat, signal emission, and kill switch behavior for the P0.1 bouquet availability refresh lane.

Signals emitted:

availability_refresh_status
availability_refresh_lag_minutes
worker_heartbeat_status

Kill switch:

ENABLE_AVAILABILITY_REFRESH
4. Run item availability scaffold
pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_item_availability.ps1" -Environment "dev"

Expected result:

OK: item availability refresh scaffold completed.

Current mode:

DryRun

This scaffold does not write to the database yet. It proves logging, heartbeat, signal emission, and kill switch behavior for the P0.1 item availability refresh lane.

Signals emitted:

availability_refresh_status
availability_refresh_lag_minutes
worker_heartbeat_status

Kill switch:

ENABLE_AVAILABILITY_REFRESH
Kill Switch Examples
Disable worker runtime
$env:ENABLE_WORKER_RUNTIME = "false"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/emit_worker_heartbeat.ps1" -Environment "dev"

$env:ENABLE_WORKER_RUNTIME = $null

Expected result:

SKIPPED: ENABLE_WORKER_RUNTIME is disabled.
Disable bouquet availability refresh
$env:ENABLE_AVAILABILITY_REFRESH = "false"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_bouquet_availability.ps1" -Environment "dev"

$env:ENABLE_AVAILABILITY_REFRESH = $null

Expected result:

SKIPPED: ENABLE_AVAILABILITY_REFRESH is disabled.
Disable item availability refresh
$env:ENABLE_AVAILABILITY_REFRESH = "false"

pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_item_availability.ps1" -Environment "dev"

$env:ENABLE_AVAILABILITY_REFRESH = $null

Expected result:

SKIPPED: ENABLE_AVAILABILITY_REFRESH is disabled.
Runtime Logs

Local-first JSONL logs are written under:

runtime/logs/

Example worker log folders:

runtime/logs/worker_runtime/
runtime/logs/automation_contract_checker/
runtime/logs/availability_worker/
runtime/logs/availability_item_worker/

Runtime logs are intentionally ignored by Git and should not be committed.

Current Validation State

Last known validation state:

emit_worker_heartbeat              PASS
check_automation_contract_status   PASS
refresh_user_bouquet_availability  PASS / DryRun
refresh_user_item_availability     PASS / DryRun
contract checker                   RESULT: pass total_units=4 compliant=4 blocked=0

The PowerShell warning about unapproved verbs from the Logging module is currently accepted as non-blocking.

Git Rules

Before staging:

git status --short

Before committing:

git diff --cached --name-only

Do not stage:

runtime/
logs/
raw payloads
provider dumps
secrets
tokens
.env files
old ingest archive folders

Commit pattern:

git add <reviewed files only>
git status --short
git commit -m "<type>: <clear message>"
git push
Current Commit Baseline

Current known clean history before the item availability commit:

02384d2 feat: add automation contract checker and availability scaffold
fdf28a1 feat: add worker heartbeat emitter
8cac6f2 feat: add PHP worker logging helper
f3c4de3 feat: add PowerShell logging helper
1261ad1 chore: restrict repo baseline to governance automation pack
28fa4a9 Initial governance/contract pack

After committing the item availability worker, update this section with the new commit hash.

Next Planned Workers

Recommended order after item availability is committed:

1. refresh_user_series_availability.ps1
2. EPG freshness / import signal worker
3. EPG join validation gate
4. live cache quality gate runner
5. materialization queue reliability worker
6. playback preflight attribution worker

Each worker must pass the contract checker before it is considered accepted.

Development Discipline

Use this repo as a controlled implementation lane.

Rules:

One worker at a time.
One commit per clean unit.
No broad refactors.
No unreviewed legacy import.
No raw old ingest dump.
No secrets.
No runtime logs.
No worker accepted without logs, heartbeat/signals, dashboard mapping, and kill switch.

Badaboom.