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

Component: Database (Authority) - xpdgxfsp_* (8 databases)
-->

# Contextual Summary — Database (Authority)

## Component Role

MySQL server hosting 8 databases: lake_knowledge, lake_vector, content, cortex, callosum_matrix, ops, inhibitor_govenor_matrix, i_m_g_vector_context, ip. Enforces constraints. Preserves provenance. Audits all writes. Source of truth for all operational, architectural, governance data.

## Current Intent

Be the single authoritative record for system state. Enforce integrity through constraints and keys. Never accept invalid writes. Make truth auditable and traceable. Reject rather than corrupt.

## Operating Mode

Transactional writes (explicit INSERT/UPDATE/DELETE). Stored procedures handle complex logic. Views for read-only presentation. Triggers for audit logging (where implemented). No direct ORM access; all writes parameterized.

## Frequency & Cadence

Continuous operational writes (series ingest, EPG updates, job state). Nightly batch ingests (grinder → ingest workers → DB). Real-time reads (UI queries, API calls). Periodic archival/cleanup (manual or scripted).

## Pressures Detected

Schemas growing without consistent versioning. Different DBs have different table structures (no unified schema). Foreign key constraints sometimes unenforced. Audit trail incomplete (not all tables have created_at/updated_by). Raw API responses stored directly (no normalization layer).

## Active Constraints

Shared hosting (resources limited). No schema versioning. No cross-database transactions. Limited trigger support (performance concern). Credential exposure in legacy scripts (being phased out with CVI).

## Short-Horizon Goals (Now → Soon)

Unified schema pattern across all 8 DBs. Complete audit trail (who wrote, when, why). Enforce foreign keys on content references. Twin write enforcement (inhibitor_govenor_matrix ↔ i_m_g_vector_context).

## Long-Horizon Goals

Schema versioning and zero-downtime migrations. Cross-database consistency (replication or eventual consistency pattern). Query-time access control (row-level security). Decentralized autonomy (federation).

## Blind Spots

Unknown which applications write to which tables. No query logging (can't see what's being read). Unknown data lineage (where did this record originate?). No enforcement of "no direct writes" policy (legacy apps may bypass control layer).

## Friction Points

Schema changes require manual coordination. No automated testing of constraint enforcement. Audit trail requires manual trigger creation. Twin-write logic not automated (relies on application layer). Grinder output stored as JSON (requires post-ingest parsing).

## Metrics Currently Used

Database size. Table row counts. Query latency (app-level, not DB-level).

## Metrics Missing

Write volume per table. Constraint violation attempts. Audit trail completeness (% of writes captured). Data staleness (how old is the oldest record). Foreign key violations (attempted but prevented).

## Suggested Stored Procedures (Do Not Exist Yet)

- `sp_audit_write()` - universal audit logging (actor, table, operation, before/after)
- `sp_verify_twins()` - check consistency between inhibitor_govenor_matrix and i_m_g_vector_context
- `sp_get_data_lineage()` - trace record origin (source table, timestamp, actor)
- `sp_enforce_schema_version()` - validate incoming writes against canonical schema

## Desired Context From Other Components

Grinder: Which grinder outputs failed to ingest (and why)? Governance: Which tables require twinning? Ops: Which job writes succeeded vs. failed? CVI: What are the allowed write patterns?

## Confidence Level

High on current state (schema is queryable, constraints are explicit). Medium on write source (who writes what?). Low on data lineage (how did this record get here?).

## Notes

Database is purely defensive: it enforces what's allowed, doesn't determine what should happen. This is correct design but creates blind spot: DB rejects bad writes but can't advise what's good. That judgment lives in application layers.
