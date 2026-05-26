# P0 Remediation Backlog (Ranked) - 2026-05-26

Status: Approved as MVP backend/automation hardening track (2026-05-26).

## Ranking Method
Rank = impact on user-visible correctness x blast-radius risk x current gap severity.

## Operating Principles (Must Preserve)
- Do not hard-delete provider/user availability data.
- Mark stale/unavailable instead.
- Keep known-good cache available during refresh failures.
- Treat failure as signal.
- Make workers observable before trusting automation.

## Observability Contract (Applies to Every P0 Item)
Each P0 item must produce at least one visible diagnostic field or dashboard signal. If automation runs without observable output, risk is not considered reduced.

## Batch / Worker Logging Requirement
Status: Accepted (2026-05-26).

All recreated or modified batch, ingest, worker, materializer, and repair components must include structured logging.

Implementation gate:
- No recreated ingest/batch/worker file is accepted unless it includes structured logging and heartbeat compatibility.
- A component is not implementation-complete unless its logs support dashboard visibility and failure diagnosis.

Minimum required events:
- `job_started`
- `job_progress`
- `job_completed`
- `job_failed`
- `heartbeat`
- `checkpoint_saved`
- `source_row_count`
- `rows_inserted`
- `rows_updated`
- `rows_skipped`
- `rows_failed`
- `duration_ms`

Minimum required fields per record:
- `job_name`
- `run_id`
- `worker_name`
- `component`
- `environment`
- `database_target`
- `source_name`
- `mac_user_id` (if user-scoped)
- `screen_type` (if screen-scoped)
- `started_at`
- `ended_at`
- `status`
- `attempt`
- `error_code`
- `error_message`

Sensitive values policy:
- `provider_username = REDACTED`
- `provider_password = REDACTED`
- `token = REDACTED`
- `api_key = REDACTED`
- `full_playback_url = REDACTED` or hashed

Applies to all recreated or touched components under ingest automation surfaces:
- `C:\miraTV_ingest` / `C:\miratv_ingest`
- `_workers`
- `_ingest`
- `tools`
- `triggers`
- batch runners
- materializers
- EPG importers
- availability refresh workers
- queue consumers
- cache refresh workers
- quality gate scripts

Practical implementation rule:
- Include at least one standardized logging call in each recreated/touched component, for example:
	- `write_worker_log(...)`
	- `write_job_event(...)`
	- `emit_heartbeat(...)`
	- `write_quality_gate_result(...)`
	- `write_materialization_event(...)`

## P0.1 User Availability Refresh Lanes (Bouquet/Item/Series)
Priority: 1
Why now:
- Current evidence points to 406 errors frequently caused by access/bouquet drift.
- Without this, playback and cache diagnosis remain noisy and misleading.

Scope:
- `ip.user_bouquet_availability`
- `ip.user_item_availability`
- `ip.user_series_availability`
- link into `user_provider_sync_profile`

Implementation:
1. Build refresh worker with per-user/provider idempotency key.
2. Add stale expiry + unavailable marking (no hard delete).
3. Emit diagnostics classification for 406 as access lane.

Acceptance:
- 406 events classified >= 95%.
- Availability refresh lag <= 30 minutes.
- False playback debugging incidents trend down.

Required diagnostic signal:
- `availability_refresh_status` (values: `fresh`, `stale`, `unavailable`) and `availability_refresh_lag_minutes`.

Rollback:
- Disable availability worker via kill switch.
- Keep previous known-good availability rows active until TTL.

## P0.2 Worker Heartbeat and Runtime Signal Baseline
Priority: 2
Why now:
- Automation cannot be trusted without visibility.

Scope:
- job runs/events heartbeat fields
- error and attempt counters
- stale counters by domain

Implementation:
1. Add heartbeat row for each critical worker.
2. Standardize status fields across units.
3. Add missing-heartbeat alert rules.

Acceptance:
- Critical heartbeat compliance = 100%.
- No silent worker failure > 2 intervals.

Required diagnostic signal:
- `worker_heartbeat_status` (values: `healthy`, `late`, `missing`) and `last_heartbeat_at` per critical worker.

Rollback:
- Revert worker rollout and keep stale-serving mode.

## P0.3 EPG Freshness + Join Correctness Gate
Priority: 3
Why now:
- Live now/next quality and guide correctness depend on accurate EPG joins and freshness.

Scope:
- EPG fetch cadence
- import dedupe/retention policy
- strict join validation rules

Implementation:
1. Enforce post-import validation rule for approved join paths.
2. Block downstream live-now materialization when join validation fails.
3. Add stale alarm when EPG age exceeds SLA.

Acceptance:
- EPG max staleness <= 6h.
- Join validation pass rate = 100% in steady state.
- Forbidden join pattern appears 0 times in query paths.

Required diagnostic signal:
- `epg_freshness_age_hours` and `epg_join_validation_status` (values: `pass`, `fail`).

Rollback:
- Freeze new EPG materialization and serve prior known-good EPG cache.

## P0.4 Cache Stale-Serving Contract Across Live Families
Priority: 4
Why now:
- Prevents blank screens during refresh failures and supports graceful degradation.

Scope:
- Live, 24/7, PPV, Soccer, APS, home live shelves

Implementation:
1. Standardize cache response contract: `served_from`, `refresh_needed`.
2. Ensure stale-but-known-good rows are returned when refresh fails.
3. Add per-screen stale ratio telemetry.

Acceptance:
- Blank-screen due to refresh failure = 0.
- `refresh_needed` visible and accurate on stale paths.

Required diagnostic signal:
- `cache_served_from` (values: `fresh`, `stale_known_good`) and `stale_ratio_by_screen`.

Rollback:
- Disable async refresh and force serve existing valid cache snapshot.

## P0.5 Live Cache Quality Gates in Pipeline (Not Manual-Only)
Priority: 5
Why now:
- Current DB gate scripts exist but appear operationally manual.
- Duplicate and blank-key regressions can silently recur.

Scope:
- `tools/run_db_quality_gates.ps1`
- `tools/db_repair_steps.sql`
- deploy blocking on gate failure

Implementation:
1. Add scheduled gate runs with persisted results.
2. Convert gate thresholds into hard deploy checks.
3. Keep Step A/B/C safety sequencing from runbook.

Acceptance:
- Duplicate ratio <= 0.05 per screen.
- Blank key ratios <= 0.01 per key per screen.
- Filter diversity thresholds pass per screen.

Required diagnostic signal:
- `quality_gate_result` (values: `pass`, `fail`) with `duplicate_ratio`, `blank_key_ratio`, and `filter_diversity_score` by screen.

Rollback:
- Freeze automated repair steps and revert to snapshot.

## P0.6 Materialization Queue Reliability for Series/VOD Gaps
Priority: 6
Why now:
- Missing seasons/episodes/provider metadata creates broken detail/playback flows.

Scope:
- `ip.content_materialization_queue`
- queue consumers, retry/backoff, dead-letter semantics

Implementation:
1. Formalize enqueue triggers for visible-screen incompleteness.
2. Add dedupe key and priority ordering (visible-first).
3. Add terminal failure and requeue policy.

Acceptance:
- Queue oldest age within SLA.
- Dead-letter count below threshold.
- Missing episode/provider-info incidents trend down.

Required diagnostic signal:
- `materialization_queue_oldest_age_minutes`, `materialization_dead_letter_count`, and `materialization_requeue_rate`.

Rollback:
- Pause consumers; retain queue; serve existing known-good metadata.

## P0.7 Playback Preflight Attribution (406 vs 404 vs Metadata)
Priority: 7
Why now:
- Prevents misclassification and wasted debugging cycles.

Scope:
- resolver diagnostics pipeline
- structured event logging with attribution

Implementation:
1. Preflight checks for availability, routing, metadata completeness.
2. Log outcome classification per attempt.
3. Feed classification back into remediation queues.

Acceptance:
- Playback failures attributed with high coverage.
- Reduced unresolved playback incidents.

Required diagnostic signal:
- `playback_preflight_outcome` (values: `availability_406`, `routing_404`, `metadata_incomplete`, `success`) and `attribution_coverage_percent`.

Rollback:
- Disable attribution writer only; preserve playback path.

## Suggested 10-Day Execution Cadence
1. Day 1-2: P0.1 + P0.2 foundations
2. Day 3-4: P0.3 EPG gate
3. Day 5-6: P0.4 stale-serving contract
4. Day 7: P0.5 automated DB quality gates
5. Day 8-9: P0.6 queue reliability
6. Day 10: P0.7 playback attribution hardening

## Hard Stop Conditions
- Any increase in blank-screen incidents.
- Any quality gate threshold breach sustained for two consecutive windows.
- Any missing critical heartbeat for > 2 intervals.

## Evidence Anchors Used For This First Pass
- `DB_REPAIR_RUNBOOK_2026-05-25.md`
- `DB_FIRST_REPAIR_SPEC_2026-05-25.md`
- `ENDPOINT_TRUST_MAP_2026-05-25.md`
- `tools/run_db_quality_gates.ps1`
- `tools/db_repair_steps.sql`
