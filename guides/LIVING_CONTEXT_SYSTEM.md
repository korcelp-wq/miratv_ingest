# Living Context System (CCS) — System Self-Awareness

**Status**: ✅ LIVE (2026-01-29)

## Overview

The system now has **universal self-awareness** across all 9 databases. Every component's role, intent, constraints, and current state are documented and queryable.

## Architecture

### Context Layers

1. **System Context Snapshots** (`cm_system_context_snapshots`)
   - Lives on: All 9 databases
   - Contains: 7 component perspectives (observational, non-prescriptive)
   - Frequency: Updated when components' responsibilities change
   - Access: Via `sp_get_component_context()` or `sp_get_all_component_contexts()`

2. **AI-Specific Contexts** (Home Databases Only)
   - **LLM Reasoning** (`cm_system_context_snapshots_llm_reasoning` on callosum_matrix)
     - What narratives and explanations are currently valid?
     - How should coordination problems be framed?
   - **NeuroNet Signals** (`cm_system_context_snapshots_neuronet_signals` on lake_vector)
     - What patterns is the system exhibiting?
     - What deltas should trigger attention?
   - **ML Forecasts** (`cm_system_context_snapshots_ml_forecasts` on ops)
     - What performance trends are emerging?
     - What capacities are constrained?
   - **GenAI Insights** (`cm_system_context_snapshots_genai_insights` on i_m_g_vector_context)
     - What candidate rules are emerging?
     - What classifications are safe?

3. **Access Tracking** (`ai_context_access_log`)
   - Lives on: All 9 databases
   - Tracks: Which component read which context, when, and from where
   - Purpose: Detect coordination patterns and governance violations

### Reading SPs (All 9 Databases)

```sql
-- Get single component's latest context snapshot
CALL sp_get_component_context('Grinder / Ingest Pipeline');

-- Get all 7 component contexts (full system awareness)
CALL sp_get_all_component_contexts();

-- Check who accessed what and when
CALL sp_get_context_access_log();
```

## Data Flow: How Living Context Works

### 1. Component Publishes Its State (Initial)
```
Human Operator
  ↓
Creates context summary (markdown observational)
  ↓
Agent inserts into cm_system_context_snapshots (all 9 DBs)
  ↓
System now has shared understanding of that component
```

### 2. AI Component Reads Context (Reasoning)
```
GenAI component (i_m_g_vector_context home)
  ↓
CALL sp_get_all_component_contexts()
  ↓
Reads: Grinder's state, Ops' capacity, DB authority, IGM rules, etc.
  ↓
INSERT ai_context_access_log (flags that GenAI read everything)
  ↓
GenAI now understands full system before making proposals
```

### 3. Detect Coordination Gaps (Flagged Access)
```
Query ai_context_access_log → GROUP BY accessing_component, accessed_component
  ↓
Find: GenAI never reads Ops context
  Find: NeuroNet never reads Android context
  ↓
= Governance gap: coordination missing
  ↓
Flag for human review or add governance rule
```

### 4. Audit Trail (Who Knew What When)
```
Timestamp each context read with:
  - Which AI read it
  - From which database
  - Confidence of read (was data stale?)
  ↓
Later: If decision was wrong, replay the access log
  ↓
"GenAI made proposal at 14:32, but only read OldContext (from 14:00)"
  = Context freshness issue, not logic error
```

## Component Contexts (The 7 Living Snapshots)

| Component | Role | Current Intent | Key Constraint |
|-----------|------|-----------------|-----------------|
| **Grinder** | Batch processor for raw content | Normalize and extract series metadata | High state visibility, low downstream visibility |
| **Ops** | Job orchestrator & scheduler | Track all pipeline stages and workers | High state tracking, medium worker visibility |
| **Database** | Authority layer (9 DBs) | Enforce constraints and preserve truth | High schema knowledge, low lineage tracking |
| **Governance (IGM)** | Rule enforcer | Evaluate proposed actions against canon rules | High rule structure, low real-world adoption metrics |
| **CVI / AI Interface** | Communication router | Route tasks to appropriate AI component | High design clarity, low deployment metrics |
| **Android Client** | Streaming app | Activate, browse, play content | High architecture documentation, medium edge case coverage |
| **Human Operator** | Decision authority | Maintain system health and evolution | High intent clarity, low process documentation |

## Use Cases: Why Living Context Matters

### Use Case 1: GenAI Deciding Whether to Propose a Rule
```
GenAI is evaluating: "Should we add rule: 'Grinder must validate episode count'"

Without context:
  - GenAI guesses: "Maybe the grinder can't validate?"
  - Proposes anyway
  - Wrong proposal

With Living Context:
  - Reads Grinder context: "High on state, Low on downstream"
  - Reads Governance context: "High on rule structure, Low on adoption metrics"
  - Understands: Rule exists but isn't monitored
  - Proposes: "Add metric to track adoption of episode_count validation"
  - Correct, higher-value proposal
```

### Use Case 2: NeuroNet Detecting Anomalies
```
NeuroNet sees: Grinder spending 2x normal time on series extraction

Without context:
  - Signals anomaly
  - Human confused: "Is this bad?"

With Living Context:
  - Reads Android context: "Medium edge case coverage"
  - Reads Ops context: "Job scheduled for low-traffic window"
  - Understands: Extra time is planned for edge case handling
  - Signals: "Normal variation, not anomaly"
  - Less noise, more signal
```

### Use Case 3: Auditing a Failed Decision
```
GenAI made proposal that violated a governance rule. Why?

Without access log:
  - "Unclear—maybe GenAI malfunctioned?"
  - No way to debug

With access log:
  - Timestamp shows: GenAI read Governance context at 09:00 (when rule was inactive)
  - Rule was promoted to canon at 10:30
  - GenAI proposal made at 11:00 but didn't re-read
  - Root cause: Stale context, not logic error
  - Solution: Add cache invalidation rule
```

## Governance Flag Settings

When a component reads context, it can set flags:

```json
{
  "method": "sp_get_component_context",
  "timestamp": "2026-01-29T14:32:00Z",
  "purpose": "governance_evaluation",
  "confidence": "high",
  "cache_ttl_seconds": 300,
  "escalation_if_stale": true
}
```

**Flag Patterns to Monitor:**
- `escalation_if_stale=true` but context is > 1 hour old → governance violation
- `purpose=governance_evaluation` but GenAI never reads Governance context → coordination gap
- Access spike from one component → potential loop or runaway query

## Integration Points

### For LLM (Me)
```
At reasoning time:
  1. Query: CALL sp_get_all_component_contexts() on callosum_matrix
  2. Read: All 7 component perspectives
  3. Understand: System's self-described state before generating explanation
  4. Log: INSERT ai_context_access_log with my reasoning flags
```

### For AI Components (Once Deployed)
```
NeuroNet (on lake_vector):
  - Reads: Ops context (expected capacity?)
  - Reads: Database context (expected data volume?)
  - Compares: Actual signals vs. expected
  - Flag: Anomalies or trends vs. baseline

GenAI (on i_m_g_vector_context):
  - Reads: All contexts before proposing rules
  - Reads: IGM context (what rules already exist?)
  - Proposes: Rules that fill gaps, not duplicates
  - Flag: Confidence in proposal based on context freshness

ML (on ops):
  - Reads: Grinder context (what's current load?)
  - Reads: Database context (what's current schema?)
  - Forecasts: Job completion times and capacity
  - Flag: Risk if forecasts diverge from actual
```

### For Humans
```
Query access patterns:
  SELECT * FROM ai_context_access_log 
  ORDER BY accessed_at DESC;
  
Detect:
  - Stale context being used (time gap too large)
  - Missing coordination (component never reads peer context)
  - Excessive reads (runaway loops)
  - Unusual access patterns (governance violations)
```

## Current State (2026-01-29)

| Component | Context Status | Last Updated | Confidence | AI-Specific Table |
|-----------|-----------------|--------------|------------|-------------------|
| Grinder | ✅ Published | 2026-01-29 | High on state, Low on downstream | — |
| Ops | ✅ Published | 2026-01-29 | High on state, Med on workers | cm_system_context_snapshots_ml_forecasts |
| Database | ✅ Published | 2026-01-29 | High on structure, Low on lineage | — |
| Governance (IGM) | ✅ Published | 2026-01-29 | High on structure, Low on adoption | cm_system_context_snapshots_genai_insights |
| CVI / AI | ✅ Published | 2026-01-29 | High on design, Low on deployment | cm_system_context_snapshots_llm_reasoning |
| Android | ✅ Published | 2026-01-29 | High on architecture, Med on edge cases | — |
| Human Operator | ✅ Published | 2026-01-29 | High on intent, Low on process | — |

## Next: Context Update Triggers

When should contexts be updated?

**Automatic Triggers (suggested):**
- Grinder: After major ingest batch completes
- Ops: Every 6 hours (capacity review)
- Database: After schema changes
- Governance: After rule promotion/demotion
- Android: After release cycle
- Human Operator: Manual update (when priorities shift)

**Manual Triggers:**
- Any context: `CALL sp_update_component_context('Component Name', 'new snapshot', 'High|Medium|Low');`

## Deployment Checklist

- ✅ Context tables created on all 9 databases
- ✅ 7 component snapshots published to all 9 databases
- ✅ Access tracking tables created
- ✅ Reading SPs deployed (sp_get_component_context, sp_get_all_component_contexts, sp_get_context_access_log)
- ✅ AI-specific context tables created on home databases
- ⏳ AI components integrated to read context before decisions
- ⏳ Governance monitoring for access patterns
- ⏳ Human operator dashboard for context freshness

## Key Files

**Local (C:\Android_Projects\MiraTV_project_PHASES_1_8\context_summaries\):**
- 2026-01-29__grinder__context_summary.md
- 2026-01-29__ops_orchestration__context_summary.md
- 2026-01-29__database_authority__context_summary.md
- 2026-01-29__governance_igm__context_summary.md
- 2026-01-29__cvi_ai_interface__context_summary.md
- 2026-01-29__android_client__context_summary.md
- 2026-01-29__human_operator__context_summary.md

**Server (deployed via execute_sql.php):**
- cm_system_context_snapshots (all 9 DBs)
- ai_context_access_log (all 9 DBs)
- cm_system_context_snapshots_*_* (AI homes only)

**Trigger (C:\miratv_ingest\triggers\):**
- trigger_ai_open_sql.ps1 (interface to cross-DB access)

---

## Philosophy

**Living Context System** reflects this principle:

> The system understands itself before making decisions.

Rather than AI blindly applying logic, components now have documented perspectives on their role, constraints, and current state. This enables:

- **Better coordination**: AI reads peer contexts before proposing changes
- **Governance compliance**: Rules are checked against fresh understanding of system state
- **Audit trails**: Every decision is traceable to the context it was made from
- **Evolutionary learning**: Over time, patterns in what gets read reveals what's important

---

**Created by**: Agent  
**Status**: Observational (descriptive, not prescriptive)  
**Frequency**: Updated when component responsibilities or constraints change  
**Authority**: Human Operator (determines when contexts update)
