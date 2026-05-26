<!--
COPILOT INSTRUCTIONS (READ CAREFULLY):

You are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.

DO:
- Describe intent, pressure, goals, blind spots
- Use plain language
- Leave unknowns explicit

DO NOT:
- Propose solutions
- Invent metrics
- Write code
- Make decisions
- Use theory language

This file is a SITUATIONAL SNAPSHOT, not a design doc.

Component: Ops / Orchestration
-->

# Contextual Summary — Ops / Orchestration

## Component Role

Master scheduler (spine). Coordinates grinder workers. Triggers ingest sequences via PowerShell. Manages job state via `xpdgxfsp_ops` database. Tracks job_runs, job_definitions, checkpoints, failures, locks.

## Current Intent

Orchestrate reliable, repeatable, auditable batch pipelines. Prevent job collisions (locks). Track what ran, when, why. Enable human visibility into pipeline health. Provide state recovery on failure.

## Operating Mode

PowerShell-driven scheduling (manual triggers or Windows Task Scheduler). Reads job definitions from DB. Manages locks (acquisition, release). Executes workers sequentially or in parallel. Logs events to job_events table. Marks checkpoints for recovery.

## Frequency & Cadence

Scheduled nightly or on-demand. Single orchestration run per trigger. Sequential or parallel worker execution within one run. Waits for all workers to complete before marking job_runs complete.

## Pressures Detected

Job failures don't stop pipeline; jobs just error and continue. No escalation path (critical failures don't alert). Lock timeouts are manual (no auto-recovery). Checkpoint logic informal (unclear when to retry). Job state can diverge from actual worker state (ghost jobs).

## Active Constraints

Single-threaded orchestration (one spine run at a time, enforced by DB lock). No distributed orchestration. All state in ops DB (no external job queues). Workers execute on same machine as orchestrator. No cross-system coordination.

## Short-Horizon Goals (Now → Soon)

Clear visibility into job success/failure. Automated alerts for critical failures. Reliable checkpoint restart (resume from failure point). Distinguish retriable vs. permanent failures.

## Long-Horizon Goals

Distributed orchestration (multiple spines). Cross-system job dependencies. Real-time worker health monitoring. Automatic escalation for governance violations.

## Blind Spots

Worker state vs. job_runs state (did worker truly complete?). Unknown which failures are transient (network, temp file lock) vs. data (provider format changed). No feedback loop from database ingest (did downstream processes succeed?). Unclear job scheduling priority (which job should run first if queue backs up?).

## Friction Points

Manual lock management. No built-in retry logic (devs must handle). Workers must handle their own checkpointing (inconsistent). Spine doesn't know if downstream (DB ingest) succeeded. Job definitions live in DB but logic lives in scripts (two sources of truth).

## Metrics Currently Used

Job duration. Job status (success/fail). Failure count per job.

## Metrics Missing

Worker-level state (did worker finish, or did it hang?). Lock wait time. Retry count. Time-to-escalation for failures. Success rate of resumed jobs (recovery viability).

## Suggested Stored Procedures (Do Not Exist Yet)

- `sp_job_mark_retriable()` - mark failed job as safe to retry
- `sp_job_mark_permanent_failure()` - mark failed job as irrecoverable
- `sp_job_escalate_to_governance()` - route critical failure to IGM
- `sp_job_get_recovery_state()` - return checkpoint data to resume from

## Desired Context From Other Components

Grinder: Which output files are valid? Database: Which grinder output was successfully ingested? Governance: Are job failures violations or expected? Human Operator: Do you want to retry this job or escalate?

## Confidence Level

High on current state (job_runs table is observable, locks are explicit). Medium on worker state (unclear if worker completed or hung). Low on downstream effects (can't see if DB ingest succeeded).

## Notes

Orchestration is effectively a state tracker and task sequencer, not an enforcer. It coordinates but doesn't validate. This separation is intentional but creates blind spot: spine doesn't know if its tasks actually succeeded.

