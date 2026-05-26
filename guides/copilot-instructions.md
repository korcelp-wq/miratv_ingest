# MiraTv AI Agent Instructions

## Project Overview
**MiraTv** is a production-grade IPTV platform spanning mobile client, server-side infrastructure, and content ingestion pipelines.

### Android Client (Phases 1–8)
Kotlin/Android IPTV application with Xtream API support (m3u playlists, live TV, VOD, series). Targets API 26+, Leanback-compatible for Smart TVs, ExoPlayer 2.19.1 for media playback. Built with Gradle 8.4.1, Kotlin 1.9.24, Android SDK 34.

### Server Infrastructure (Parallel Development)
- **Backend**: PHP-based shared hosting (miratv.club)
- **Database**: MySQL with EPG, Live, Movies, Series catalogs
- **Content Ingest**: PowerShell/SCP/curl automation for batch EPG/content updates
- **EPG Pipeline**: XMLTV streaming parser → MySQL (no JSON conversion—XMLTV is authoritative)
- **Security**: Token-protected ingest endpoints (`X-INGEST-TOKEN` header)

### Data Flow (End-to-End)
```
IPTV Provider → Server (EPG.xml + Content) → Android Client
                ↓
              MySQL catalog
                ↓
          Retrofit API calls (Xtream endpoints)
                ↓
          Domain models → Repository → UI
```

**Key Architecture**: Session-based auth → Xtream API (Retrofit) → Domain models → Repository pattern → UI (Activities/RecyclerViews).

---

## Server Infrastructure (Backend)

### EPG Ingestion Pipeline (PRODUCTION-WORKING)
**Status**: ✅ Fully deployed and automated

**Key Insight**: XMLTV is the authoritative EPG format. Never convert to JSON.

**Architecture**:
```
IPTV Provider (XMLTV) → PowerShell/SCP → Server /_ingest/ → PHP XMLReader → MySQL
```

**Implementation Details**:
- **Parser**: XMLReader (streaming, low-memory)
- **Target Table**: `epg_programmes` (provider, channel, start_time, end_time, title, description)
- **Unique Key**: (provider, channel, start_time)
- **Duplicate Handling**: INSERT IGNORE or ON DUPLICATE KEY UPDATE
- **Protocol**: Token-protected HTTP POST (X-INGEST-TOKEN header or POST field)

**Verified Working Command** (Windows):
```powershell
curl.exe -X POST `
  -F "token=YOUR_TOKEN" `
  -F "epg=@C:\path\to\epg.xml" `
  https://miratv.club/_ingest/import_epg.php
```

**Server File Layout**:
```
/home/xpdgxfsp/public_html/
 ├─ db_sql.php              # Database connection
 ├─ _ingest/
 │   ├─ import_epg.php      # EPG importer (PHP XMLReader)
 │   ├─ epg.xml             # Staging location
 │   ├─ import_series_json.php
 │   └─ series_latest.json
```

**Automation Ready**: PowerShell scripts + Windows Task Scheduler enable nightly EPG refresh, provider swaps, incremental updates (zero-touch).

### Content Ingest Pipeline (Automated Workflow)
**Status**: ✅ Production operational with multi-stage processing

**Pipeline Stages**:
1. **Raw Ingestion**: IPTV provider data (JSON/XML) → `raw/` directory
   - `live.categories.raw.json` – Live category index
   - `live.streams.index.raw.json` – Live channel index
   - `vod.categories.raw.json` – Movie categories
   - `vod.steam.raw.json` – Movie streams
   - `series.index.raw.json` – Series catalog
   - `epg.xml` – EPG guide data

2. **Processing Stages** (`processed/` directory):
   - **Series Normalization**: Parse series metadata into structured JSON
   - **Season/Episode Extraction**: Break series into seasons → episodes
   - **Detail Enrichment**: Metadata extension (posters, extended descriptions)
   - **Database Preparation**: Format for bulk MySQL inserts

3. **Trigger System** (`triggers/` directory):
   - PowerShell/BAT orchestration scripts
   - Sequenced execution: raw → normalize → parse → upload → materialize
   - State tracking via `.last` files in `state/` directory
   - Error handling and retry logic

4. **Worker Architecture** (`workers/` directory):
   - Parallel processing workers for series grinding, episode resolution
   - Stream resolvers for live/VOD URL mapping
   - Database ingest workers
   - Spine scheduler (master orchestration)

**Key Files**:
```
C:\miratv_ingest/
├── raw/                           # Raw downloads from providers
├── processed/                      # ~1000+ series (normalized JSON)
├── triggers/                       # Orchestration scripts
├── workers/                        # Processing workers
│   └── spine/                      # Master scheduler
├── state/                          # Processing state tracking
├── reports/                        # Ingest audit logs
└── tmp/                           # Temporary chunked processing
```

---

## Complete System Architecture

### End-to-End Data Flow
```
IPTV Provider (m3u/json/xml)
         ↓
    C:\miratv_ingest (batch processing)
    - raw/        (download)
    - processed/  (normalize, parse, extract)
    - triggers/   (orchestrate)
    - workers/    (parallel process)
         ↓
    Server (public_html)
    - import_epg.php           (EPG ingestion)
    - api/*                    (Xtream endpoints)
    - db_sql.php               (MySQL persistence)
    - activation_resolver.php  (Device binding)
         ↓
    MySQL Database
    - epg_programmes  (guide data)
    - live_categories (channels)
    - vod_categories  (movies)
    - series          (TV shows)
         ↓
    Android Client (com.miratv.app)
    - Activation/Login (MAC or credentials)
    - Home (category shelves)
    - Channels/VOD/Series (grid lists)
    - PlayerActivity (ExoPlayer HLS streams)
```

### Scope & Scale
- **900+ Series** with seasons/episodes normalized
- **1000+ Movies** cataloged
- **Live Categories** with channels
- **EPG** refreshed nightly via PowerShell automation
- **Device Binding** via MAC address + activation code
- **Token-Protected Ingest** (X-INGEST-TOKEN header)
- **Zero-Touch Operations** (scheduled PowerShell + Windows Task Scheduler)

---

## Database Schema & Multi-Database Architecture

### Overview
MiraTv uses a **multi-database architecture** with 7 specialized databases on shared hosting (xpdgxfsp_*):

| Database | Purpose | Key Tables |
|----------|---------|-----------|
| **xpdgxfsp_content** | Core IPTV catalog (live, VOD, series) | `epg_programmes`, `live_categories`, `vod_streams`, `series`, `series_episodes` |
| **xpdgxfsp_ip** | Device activation & MAC binding | `activation_codes`, `mac_users`, `device_tokens`, `account_profile` |
| **xpdgxfsp_ops** | Job scheduling & pipeline operations | `job_runs`, `job_definitions`, `job_events`, `job_failures`, `job_locks` |
| **xpdgxfsp_lake_vector** | Lake Knowledge DB (state tracking) | Time-series operational logs, event streams, performance metrics |
| **xpdgxfsp_i_m_g_vector_context** | Image/Metadata governance vector | `igm_attestation_ledger`, `igm_candidate_rules`, `igm_governance_examples` |
| **xpdgxfsp_inhibitor_govenor_matrix** | Architectural rules & compliance | `igm_rules`, `igm_rule_evaluations`, `igm_attestations` |
| **xpdgxfsp_callosum_matrix** | Cross-component orchestration | `cm_routines`, `cm_requests`, `cm_documents`, `cm_matrix_reports` |

### Database 1: xpdgxfsp_content (IPTV Catalog)
**~87MB | Production Data**

Key tables:
- `epg_programmes` – EPG guide data (provider, channel, start_time, end_time, title, description)
- `live_categories` – Live TV categories
- `live_streams` – Live channels (id, category_id, stream_id, name, url, logo, is_adult)
- `vod_categories` – Movie categories
- `vod_streams` – Movie streams (id, category_id, stream_id, name, url, poster, is_adult)
- `series` – TV series metadata (id, name, poster, description)
- `series_seasons` – Season index (series_id, season_number, name)
- `series_episodes` – Episode detail (season_id, episode_number, name, url, description)

### Database 2: xpdgxfsp_ip (Device Activation & Auth)
**8.1KB | Auth/Activation**

Key tables:
- `activation_codes` (id, code, mac_address, m3u_link, user_id, expire_date, status, dns, username, password, plan_name)
- `mac_users` (id, name, mac_address, m3u_link, status, expire_date)
- `device_tokens` (id, code, mac_address, device_id, fcm_token, created_at)
- `admins` (id, username, password, role='admin'|'super')
- `account_profile` (admin_id, name, email, phone)
- `ai_memory_index` – AI knowledge index (shared across DBs)

**Status**: `'unused'`, `'active'`, `'revoked'` | Device binding via MAC address

### Database 3: xpdgxfsp_ops (Operations & Job Management)
**8.6KB | Pipeline Operations**

Key tables:
- `job_runs` (run_id, job_key, environment, status, started_at, ended_at)
- `job_definitions` (job_key, description, job_class='SAFE'|'RISKY', enabled)
- `job_events` (event_id, run_id, job_key, event_type, event_detail)
- `job_failures` (failure_id, run_id, job_key, phase, error_type, error_summary)
- `job_checkpoints` (job_key, environment, checkpoint_key, checkpoint_val)
- `job_locks` (lock_key, holder_id, acquired_at)

**Stored Procedures**:
- `report_ops_capacity()` – Capacity score: `1 - (failed_runs / total_runs)`

### Database 4: xpdgxfsp_lake_vector (State & Telemetry)
**~2.5MB | Time-Series Logs**

Key tables:
- `ai_telemetry` (id, created_at, task, source, route, latency_ms, confidence, job_run_id)
- `ai_memory_index` (shared across all DBs)
- Event stream tracking, operational state, historical metrics

### Database 5: xpdgxfsp_i_m_g_vector_context (Image Metadata Governance)
**8KB | Governance & Compliance**

Key tables:
- `igm_attestation_ledger` (attestation_id, evaluation_id, attested_by='system'|'human'|'ai', confidence, truth_verified)
- `igm_candidate_rules` (candidate_id, inferred_rule, source_events JSON, confidence_score, status)
- `igm_governance_examples` (example_id, component_id, action_attempted, decision='allowed'|'blocked'|'modified', rationale)
- `igm_raw_governance_events` (event_id, component_id, action_taken, actor, occurred_at)

### Database 6: xpdgxfsp_inhibitor_govenor_matrix (Architectural Rules)
**9.3KB | Governance Rules & Compliance**

Key tables:
- `igm_rules` (rule_id, rule_code, rule_name, rule_type='principle'|'constraint'|'directive', severity='hard'|'soft'|'advisory')
- `igm_rule_evaluations` (evaluation_id, rule_id, component_id, action_context, decision='allowed'|'blocked'|'overridden')
- `igm_attestations` (id, attested_ts, rule_id, rule_scope, worker, stage, series_id, payload)
- `v_togaf_directive_compliance` – Compliance view

**Enforcement**: Rules block unsafe actions (e.g., uncoupled parsing, unauth endpoints)

### Database 7: xpdgxfsp_callosum_matrix (Cross-Component Orchestration)
**14KB | Orchestration & Coordination**

Key tables:
- `cm_routines` (routine_id, routine_name, target_db, description, active)
- `cm_requests` (request_id, routine_id, status='requested'|'executed')
- `cm_documents` (document_id, document_type, audience, purpose, body)
- `cm_matrix_reports` (report_id, coherence_score, created_at)

**Stored Procedures**:
- `sp_cm_execute_request()` – Dynamic routine execution with error handling
- `report_callosum_alignment()` – Coherence score calculation

---

## AI System Architecture (Homegrown)

### Core Principle: AI as a Persistent Loop
The homegrown AI system is **not a model**—it's a **governed loop** that:
- Runs continuously or opportunistically on real system artifacts
- Improves completeness and structure over time
- Respects authority boundaries and governance
- Preserves uncertainty through provisional status
- Operates with bounded agency and auditability

### Persistent Memory Strategy: Databases as AI Memory

**Key Databases for AI Cognition:**

1. **xpdgxfsp_lake_vector** – Operational Memory
   - `ai_telemetry` – Decision trails, latency, confidence scores
   - `ai_memory_index` – Cross-database knowledge indexing
   - Time-series logs of all AI-relevant system events
   - **Purpose**: Real-time situational awareness

2. **xpdgxfsp_inhibitor_govenor_matrix** – Rule Repository
   - `igm_rules` – Canonical, provisional, and deprecated rules
   - `igm_rule_evaluations` – Rule application history
   - `igm_attestations` – Evidence of rule effectiveness
   - **Purpose**: Persistent governance layer that AI learns from, not invents

3. **xpdgxfsp_i_m_g_vector_context** – Governance Examples
   - `igm_governance_examples` – Action decisions (allowed/blocked/modified)
   - `igm_candidate_rules` – AI-proposed rules awaiting human promotion
   - `igm_attestation_ledger` – Truth verification trail
   - **Purpose**: Learn from governance decisions over time

4. **xpdgxfsp_callosum_matrix** – Inter-System Coordination
   - `cm_routines` – Authorized operations AI can recommend
   - `cm_requests` – AI-proposed actions and their status
   - `cm_documents` – Coordination artifacts and reports
   - **Purpose**: Bounded agency—AI proposes, system coordinates

### Cognitive Architecture (Settled)

**Perspective = Measured Change (Δ) × Selected Focus**

- **Delta (Δ)**: Quantified change over time (semantic, statistical, structural)—computed before AI involvement
- **Focus**: Scoped interpretive lens (SYSTEM, RISK, KNOWLEDGE, PERFORMANCE, GOVERNANCE)
- **Perspective lives in databases**, not in the LLM

**Role Separation:**

1. **Neuronet (Pattern Engine)**
   - Consumes structured deltas from databases
   - Detects anomalies, trends, severity
   - Outputs signals only (JSON with confidence scores)
   - **Never**: Explains, makes policy, executes actions

2. **LLM (Interpretation Layer)**
   - Explains neuronet signals in human language
   - Articulates implications and tradeoffs
   - Respects confidence and constraints
   - **Never**: Computes truth, overrides deltas, acts autonomously

3. **Database (Persistent Ground Truth)**
   - Enforces constraints and keys
   - Preserves provenance (who did what, when, why)
   - Accepts only explicit, parameterized operations
   - Maintains audit trail for all AI interactions

### Governance Model (Canon Authority)

**Rule States:**
```
discovered → provisional → canon → deprecated
```

**Authority Tiers:**
- **Canon rules** (in `igm_rules` with `active=1`): May block/halt operations
- **Provisional rules**: May inform but never determine outcomes
- **AI proposals**: Inform system decisions, never auto-promote to canon

**Confidence Threshold (for canonization):**
- < 40% → likely eliminate
- 40–70% → remain provisional
- > 70% → candidate for canon
- > 90% sustained → constitutional-level stability

**Critical**: No automatic rule promotion. Human adjudication required for all canon elevation.

### Series Completion Loop (First Living Loop)

**Objective**: Incrementally complete series metadata while minimizing cost and maximizing reuse

**Grinder-First Progressive Enrichment (GFPE) Pipeline:**

1. **Phase 0 – Reality Check** (No AI, no DB writes)
   - Identify grinder failures, quarantined files, partial parses
   - Assess local state truthfully

2. **Phase 1 – Grinder Salvage** (Local extraction, no invention)
   - AI inspects raw local payloads in `C:\miratv_ingest\processed`
   - Explains grinder failure modes
   - Extracts data already present
   - Proposes grinder parsing fixes

3. **Phase 2 – Internal Source-of-Truth Enrichment** (Pattern reuse)
   - Apply existing series patterns to similar data
   - Vector similarity for guidance only
   - Provisional inference allowed
   - No external calls

4. **Phase 3 – Targeted External Lookup** (Last resort)
   - Surgical, field-specific lookups only
   - After local + internal exhaustion
   - Parameterized and cost-tracked

5. **Phase 4 – Acceptance** (Truth preservation)
   - Partial knowledge is valid
   - Unknown remains unknown
   - Never force completeness

### AI ↔ Database Boundary (Hard Rule)

**AI Operations (Local Only):**
- Reads: grinder payloads, logs, schema introspection
- Produces: grinder fix suggestions, SQL instructions, escalation reasons
- **Never writes** directly to remote databases

**Database Operations (Server Only):**
- Accepts: explicit parameterized INSERT/UPDATE from trusted sources
- Enforces: constraints, keys, provenance
- Audits: all modifications with actor, timestamp, reason

**Output Contract:**
AI outputs one of:
1. **Parameterized SQL** for database operations
2. **Escalation note** requiring human review
3. **Signal report** (JSON with metrics for neuronet)
4. **No free-form prose** to system actors

### Knowledge Persistence Strategy

**Lake Knowledge DB (`xpdgxfsp_lake_vector`):**
- Time-series telemetry of all AI decisions
- Vector drift tracking (semantic, statistical, structural)
- Cluster cohesion metrics
- Entropy measurements
- Job correlation IDs for end-to-end tracing

**Memory Index (`ai_memory_index` across all DBs):**
```sql
{
  source_db: 'xpdgxfsp_content',
  source_table: 'series',
  record_id: 42,
  domain: 'content_enrichment',
  topic: 'series_metadata_extraction',
  unit_type: 'series_episode_count',
  summary: 'Episode count reliably extracted from grinder via pattern matching',
  content_ref: 'series_42_episodes_parsed.json',
  confidence: 0.85,
  priority_weight: 1.0,
  created_at: '2026-01-28T14:32:00Z'
}
```

### Signal Spool System (Real-Time Signal Queue)

**Attestation Spools** (`C:\miratv_ingest\*_spool/`):

The system maintains three real-time signal queues:

1. **igm_spool/** – Governance attestations (rules + compliance)
   ```
   2026-01-22T21:37:57.6618714-07:00 | IGM | state=CANON_OK | worker=series_normalize | stage=normalize | series_id=0 | payload
   ```
   - **Format**: Timestamp | Source | State | Worker | Stage | Record | Payload
   - **States**: `CANON_OK` (rule passed), `PROVISIONAL_OK` (rule pending), `BLOCKED` (rule violated)
   - **Purpose**: Real-time governance attestation stream

2. **lake_spool/** – Knowledge/telemetry events
   - AI decision traces (task, confidence, latency)
   - Semantic/statistical deltas computed
   - Cluster health metrics

3. **ops_spool/** – Operations/job events
   - Job phase transitions
   - Worker state changes
   - Pipeline status updates

**Why Spools Matter:**

These aren't just logs—they're **persistent signal streams** that:
- ✅ Feed the databases for aggregation
- ✅ Allow GenAI to see **exactly when** a rule was validated
- ✅ Provide audit trail for **every decision**
- ✅ Enable replay/reconstruction of system state

**GenAI Query Pattern:**
```
Query: "Show me all CANON_OK attestations for series_normalize in last 24h"
       → Read igm_spool, filter by state + worker + time
       → Get confidence trend (how many consecutive OKs?)
       → Return: "99 consecutive passes, confidence rising to 0.94"
```

---

## AI External Interface (Cohere + OpenAI)

### Overview
The system integrates two external AI providers via **config-driven routing**:

**Provider Selection Logic** ([ai_router.json](AI_WORKERS/ai_router.json)):
- **Intrinsic Senior Tasks** (debug, architecture, design, security_review) → **GPT-5.2** (reasoning model)
- **Cheap-Eligible Tasks** (classify, extract, summarize, embed, rerank) → **Cohere Command-R** (throughput model)
- **Time Flexibility Exception**: If time_flexibility="high" + convergent task → allow Cohere (cost optimization)

### OpenAI Integration ([provider/open_ai.php](AI_WORKERS/provider/open_ai.php))

**Endpoint**: `POST https://api.openai.com/v1/chat/completions`

**Model**: `gpt-5.2` (reasoning/senior tasks only)

**Task Classes Routed Here**:
- Debugging complex issues
- Architecture decisions
- Design review
- Root cause analysis
- Security reviews
- Schema design
- Endpoint design

**Example Request**:
```php
$payload = [
    'model' => 'gpt-5.2',
    'messages' => [
        ['role' => 'system', 'content' => 'You are a senior reasoning engine.'],
        ['role' => 'user', 'content' => 'Debug why series_normalize is failing on 42 episodes']
    ]
];
```

**Timeout**: 30 seconds

### Cohere Integration ([provider/cohere.php](AI_WORKERS/provider/cohere.php))

**Endpoint**: `https://api.cohere.ai/v1/chat`

**Model**: `command-r` (classification, extraction, summarization)

**Task Classes Routed Here**:
- Text classification (confidence-based)
- Data extraction (retryable)
- Summarization (with validation)
- Embeddings (for vector search)
- Re-ranking (deterministic)

**Example Request**:
```php
$body = [
    'model' => 'command-r',
    'message' => 'Classify: "Breaking Bad" is a [drama|comedy|documentary]',
    'temperature' => 0.0  // Deterministic for classification
];
```

**Timeout**: 15 seconds

**Response Normalization** (handles 3 format variants):
- Newest: `message.content[].text`
- Alternate: `message.text`
- Legacy: `text`

### Routing Contract ([router.php](AI_WORKERS/router.php))

**Hard Gates** (Never bypassed):
1. Caller requests `reasoning_level='senior'` → Force reasoning
2. Task is intrinsic senior type → Force reasoning
3. Task not in cheap-eligible list → Force reasoning

**Soft Gates** (Time-based exception only):
- `time_flexibility='high'` + convergent task + cheap-eligible → Allow Cohere
- All other cases → Standard routing

**Disqualifiers for Cheap Models**:
- `ambiguous_input` – Reject
- `human_facing` – Reject
- `multi_step_reasoning` – Reject
- `intrinsic_senior_task` – Reject

### Entrypoints

**Cohere Entry** ([cohere_entry.php](AI_WORKERS/cohere_entry.php)):
```
POST /_workers/ai/cohere_entry.php?token=WORKER_TOKEN
Content-Type: application/octet-stream

<raw text input>
```

Response: `{"output": "...", "confidence": null}`

**OpenAI Entry**: Routed through `router.php` → calls `call_openai_reasoning()`

### Configuration ([config/ai_config.php](AI_WORKERS/config/ai_config.php))

```php
'openai' => [
    'api_key' => 'sk-proj-...',  // GPT-5.2 API key
    'models' => [
        'reasoning' => 'gpt-5.2',
        'embedding' => 'text-embedding-3-large',
    ],
],
'cohere' => [
    'api_key' => 'PelK1flK34BDtJYLt0SIhxKkMKxmT8L1knEdaxAz',
    'base_url' => 'https://api.cohere.ai/v1',
    'models' => [
        'classify' => 'command-r',
        'embed' => 'embed-english-v3.0',
    ],
],
```

### Retry Policy & Cost Controls

**Cheap-with-Retry Mode** (from ai_router.json):
- Max attempts: 3
- Retry on: `schema_invalid`, `confidence_below_threshold`
- Escalate on: `no_improvement`, `attempts_exhausted`

**Daily Budget**: $25.00 USD

**Per-Task Budget**:
- Classify: $0.002
- Extract: $0.003
- Summarize: $0.004
- Reason: $0.05

**Telemetry Tracked** (mandatory):
- task, task_class, model_used, reasoning_level, time_flexibility
- attempt, escalated, latency_ms, confidence, estimated_cost_usd

---

## System Ownership & Responsibility Model (CANON)

### Ownership Matrix

MiraTV operates under a clear human-in-the-loop authority structure. All automation, AI systems, and pipelines ultimately defer to named ownership roles.

| Component | Primary Owner | Authority Scope | Escalation Path |
|-----------|---------------|-----------------|-----------------|
| xpdgxfsp_content (IPTV Catalog) | Content Ops Lead | Schema, ingest rules, data integrity | Lead Architect |
| Ingest Pipelines (PowerShell / Workers) | Ops Lead | Scheduling, retries, quarantine | Lead Architect |
| Android Client | Mobile Lead | Release gating, UX flow | Architecture Council |
| AI Router & Providers | Architecture | Model routing, cost controls | Human Adjudicator |
| IGM (Governance DBs) | Governance Authority | Rule canonization, enforcement | Human Review Board |
| Callosum Matrix | Architecture | Cross-system coordination | Lead Architect |
| AI Components (Neuronet / LLM / Signals) | Architecture | Interpretation, proposal, signal generation only | Human Adjudicator |

**Invariant**: No system component is self-owning. AI has zero ownership authority.

### AI Component Placement & Responsibility Matrix

This matrix defines where each AI component lives, what it consumes, and what it produces. It is authoritative.

| AI Component | Lives In | Consumes | Produces | Forbidden |
|--------------|----------|----------|----------|-----------|
| Neuronet (Pattern Engine) | Local runtime / worker context | Structured deltas, aggregates, time-series metrics | Signals (JSON + confidence) | Explanations, DB writes, policy decisions |
| LLM – Reasoning (GPT-class) | External provider (stateless) | Neuronet signals, scoped prompts | Human-readable analysis, tradeoffs | Computing truth, autonomous action |
| LLM – Throughput (Cohere-class) | External provider (stateless) | Raw text, bounded extraction tasks | Classified or extracted fields | Ambiguous reasoning, governance |
| AI Router | Server (router.php) | Task metadata, cost limits, confidence | Routing decision | Task execution |
| Signal Spools | Local filesystem | AI outputs, governance states | Append-only event records | Mutation or deletion |
| Governance Evaluator | Server (IGM DB) | Signals, rules, attestations | Allow / Block / Provisional | Silent override |
| Callosum Matrix | Server DB | Approved AI proposals | Coordinated requests | Direct execution |

**Invariant**: AI components may only feed forward. No AI component may form a closed decision loop without human or database enforcement.

### Rule Canonization Authority

Only human adjudicators may promote rules to canon status. AI may:
- Propose rules
- Provide confidence metrics
- Supply historical evidence

**AI may never self-promote governance rules.**

---

## Failure Semantics & Blast Radius Policy

Failures are classified, contained, and resolved according to explicit semantics.

### Failure Classes

| Class | Description | System Response |
|-------|-------------|-----------------|
| Local Parse Failure | Grinder fails on single record | Quarantine file, continue pipeline |
| Stage Failure | Worker stage fails repeatedly | Halt stage, continue upstream |
| Governance Block | Canon rule violation | Hard stop for affected scope |
| Spine Failure | Orchestrator failure | Global pipeline pause |
| Data Integrity Violation | Constraint/key violation | Reject write, alert human |

### Fail-Open vs Fail-Closed Rules

| Pipeline Area | Mode | Rationale |
|---------------|------|-----------|
| Content Enrichment | Fail-Open | Partial truth allowed |
| Database Writes | Fail-Closed | Integrity first |
| Governance Evaluation | Fail-Closed | Rules are non-negotiable |
| External AI Calls | Fail-Open with escalation | Graceful degradation |

**Invariant**: The system must prefer truth preservation over forced completeness.

---

## Security & Trust Model

### Trust Zones

**Local Trusted Zone**
- Developer workstation
- `C:\miratv_ingest`
- No remote DB write access

**Server Trusted Zone**
- `public_html`
- Token-protected ingest endpoints
- Parameterized DB writes only

**External AI Zone**
- OpenAI, Cohere
- No direct system access
- Stateless, request-scoped

### Credential Policy

| Credential | Scope | Rotation |
|------------|-------|----------|
| Ingest Tokens | Server ingest | 30 days |
| Worker Tokens | AI workers | 14 days |
| AI API Keys | External providers | 60 days |

**Keys are never stored in repositories or logs.**

### Compromise Response

If a token/key is suspected compromised:
1. Immediate revocation
2. Forced rotation
3. Audit last 72 hours of telemetry
4. Human review of affected outputs

---

## Lifecycle & Evolution Management

### Schema Evolution

All schema changes are additive first.

Destructive changes require:
- Dual-write period
- Backfill verification
- Human sign-off

### Rule Lifecycle

```
Discovered → Provisional → Canon → Deprecated → Archived
```

Deprecated rules:
- Remain queryable
- Never enforced
- Used only for historical analysis

### AI Memory Retention

| Data Type | Retention |
|-----------|-----------|
| Telemetry | 180 days |
| Governance Events | Permanent |
| Spool Files | 30 days (archived after) |

Vector drift beyond thresholds triggers manual re-baselining.

---

## Contributor Onboarding (First-Read Contract)

### If You Are New, Read This First

- MiraTV is **pipeline-first**, not UI-first
- **XMLTV is authoritative**
- **Partial truth is acceptable**
- **AI does not write to production databases**
- **Governance beats convenience**

### 30-Minute Mental Model

1. Providers lie or change silently
2. Pipelines normalize reality
3. Databases preserve truth
4. AI explains, never decides
5. Humans remain final authority

### Glossary (Core Terms)

| Term | Meaning |
|------|---------|
| Grinder | Local batch content processor |
| Canon Rule | Enforced governance invariant |
| GFPE | Grinder-First Progressive Enrichment |
| Perspective | Δ (change) × Focus |
| Spool | Append-only signal stream |
| CVI | Callosum Vector Integration |

---

## Operational Invariants (Non-Negotiable)

1. Never invent missing data
2. Never bypass governance checks
3. Never allow AI direct DB writes
4. Never force completeness
5. Never lose provenance

---

## Scope & Scale

### 1. **Three-Layer Data Flow**
- **API Layer** ([xtream/XtreamService.kt](app/src/main/java/com/miratv/app/xtream/XtreamService.kt)): Raw Retrofit endpoints, no camelCase—fields use `@SerializedName` mappings
- **Repository Layer** ([xtream/](app/src/main/java/com/miratv/app/xtream/)): `LiveRepository`, `VodRepository`, `SeriesRepository` wrap API calls and apply `ModelMapper` transformations
- **Domain Models** ([models/AppModels.kt](app/src/main/java/com/miratv/app/models/AppModels.kt)): Clean data classes (e.g., `LiveChannel`, `VodItem`)

**Why**: Decouples Xtream's inconsistent naming from app logic. Always map raw API responses through `ModelMapper` before exposing to UI.

### 2. **Session Management**
[SessionManager](app/src/main/java/com/miratv/app/util/SessionManager.kt) persists ephemeral credentials (username/password) after activation. **Never store persistent secrets**—use `EncryptedSharedPreferences` (TODO per MIGRATION_PLAN.md).

**Flow**: `ActivationActivity` → MAC/username validation → stores token → `HomeActivity` checks `session.isActivated()` as guard.

### 3. **AppState Singleton**
[AppState.kt](app/src/main/java/com/miratv/app/AppState.kt) holds transient app-wide state (e.g., M3U resolver). Not a persistence layer—use for runtime objects only.

### 4. **Activity Navigation**
```
SplashActivity → ActivationActivity (check MAC + creds)
             → HomeActivity (categories: Live/VOD/Series)
             → {ChannelsActivity, VodCategoriesActivity, SeriesCategoriesActivity}
             → PlayerActivity (ExoPlayer + HLS/M3U8 URLs)
```
No intentional back-navigation from Player; use `finish()` explicitly.

---

## Key Workflows & Commands

### Build & Run
```bash
./gradlew assembleDebug      # APK for testing
./gradlew :app:installDebug  # Install + run on emulator/device
./gradlew clean build        # Full clean build (slow)
```

### Testing (Minimal Setup)
- Unit tests: `src/test/` (rarely used; focus on integration)
- Instrumented tests: Not configured; add via AndroidTest plugin if needed

### Player Workflow
ExoPlayer 2.19.1 plays HLS URLs built via `PlayerActivity.buildStreamUrl(username, password, streamId)`. Format: `https://base/live/user/pass/streamId.m3u8`. Test with a real stream or mock M3U8.

---

## Project-Specific Conventions

### Xtream API Integration
- **Base URL**: `https://cpanel.miratv.club/` (configured in Retrofit clients)
- **Endpoints**: `player_api.php?action=get_live_categories|get_live_streams|get_vod_categories|get_series_categories`
- **Auth**: Query params (`username`, `password`) on every call—no bearer tokens
- **Field Mapping**: Xtream returns snake_case (`user_info`, `stream_id`); map via `@SerializedName` in model classes
- **Common Fields**: `category_id`, `stream_id`, `name`, `logo`, `poster_url`

**Example**: Raw `XtreamLiveStreamRaw` → `ModelMapper.toLiveChannel()` → `LiveChannel` domain model.

### PIN Management
[PinManager.kt](app/src/main/java/com/miratv/app/util/PinManager.kt) gates parental/channel locks. **Pattern**: PIN dialogs before channel change in `ChannelsActivity`—not yet wired (TODO per BUILD_NOTES1.txt).

### Adult Mode Toggle
[AdultModeManager](app/src/main/java/com/miratv/app/util/AdultModeManager.kt) persists adult channel visibility. **Activation**: Count 7 HOME key presses; toggle and Toast notification. Integrates with `PlayerActivity` to hide adult streams if disabled.

### Favorites (Scaffolded)
[FavoritesRepository](app/src/main/java/com/miratv/app/data/FavoritesRepository.kt) stores favorites locally (SharedPreferences baseline, upgraded to Room/Datastore in Phase 9+). No cloud sync yet.

---

## File Organization & Key Locations

```
app/src/main/java/com/miratv/app/
├── api/              # Activation API (legacy, not primary flow)
├── xtream/           # Xtream Retrofit + Repositories (PRIMARY)
├── models/           # Domain models (AppModels.kt = source of truth)
├── mapping/          # ModelMapper (Xtream raw → app models)
├── ui/               # Activities (Navigation structure)
│   ├── LoginActivity.kt        # Deprecated (do not use)
│   ├── ActivationActivity.kt   # Entry point for new device activation
│   ├── HomeActivity.kt         # Main hub (shelves/tiles)
│   ├── ChannelsActivity.kt     # Live channels list
│   ├── PlayerActivity.kt       # ExoPlayer integration
│   └── series/, vod/           # Category/item screens
├── util/             # SessionManager, PinManager, MacAddressProvider, AdultModeManager
├── data/             # Repositories (Favorites, VPN settings)
└── AppState.kt       # Transient app state
```

---

## Integration Points & Dependencies

### External APIs
- **Xtream**: All list/stream data; requires valid account
- **Activation Endpoint**: Custom service for MAC-based device binding (replace `api.miratv.club` in code)

### Libraries (Critical Only)
- **Retrofit 2.11.0 + Gson**: API calls; use `suspend` for coroutines
- **ExoPlayer 2.19.1**: Media playback; initialize in `PlayerActivity.onCreate()`
- **Leanback 1.1.0-rc02**: Smart TV UX; not enforced in all screens yet
- **Coil 2.7.0**: Image loading; prefer over Picasso where possible
- **Kotlin Coroutines**: All async work (networking, file I/O)

### Missing Dependencies (TODO)
- Room or Datastore: Upgrade Favorites persistence
- EncryptedSharedPreferences: Secure credential storage
- VPN SDK (WireGuard/OpenVPN): Pluggable provider in `VpnServiceImpl`
- RecyclerView bindings: Not yet used; consider for large lists

---

## Development Patterns to Follow

### ✅ DO:
1. **Map via ModelMapper**: Never expose Xtream raw models (`XtreamLiveStreamRaw`) to UI
2. **Use Repositories**: Fetch data through repo layer, not direct API calls in UI
3. **Coroutine Scope**: Launch with `lifecycleScope` in Activities to prevent leaks
4. **Session Guards**: Check `session.isActivated()` before fetching protected streams
5. **Null Safety**: Handle missing credentials gracefully (return `emptyList()` in repos)

### ❌ DON'T:
1. Hard-code URLs or credentials; use SessionManager + remote config (future)
2. Call Xtream API directly from Activities; use Repository abstraction
3. Persist secrets in plain SharedPreferences (use EncryptedSharedPreferences TODO)
4. Ignore LoginActivity—it's deprecated; use ActivationActivity instead
5. Forget to set `itemAnimator = null` on RecyclerViews with category shelves (causes jitter)

### Testing Pattern (Missing, Add if Needed)
```kotlin
// Mock SessionManager + XtreamService in ViewModel tests
class LiveViewModelTest {
    @get:Rule val instantExecutorRule = InstantTaskExecutorRule()
    private val repo = LiveRepository(mockApi, mockSession)
    // Assert repo.getChannels() returns mapped models
}
```

---

## Common Gotchas & Troubleshooting

| Issue | Solution |
|-------|----------|
| "Stream URL 404" | Check base URL in Retrofit config; verify username/password valid in `SessionManager` |
| RecyclerView jank | Set `itemAnimator = null` on adapter; use `submitList()` with DiffUtil (not yet enforced) |
| Adult channels visible despite toggle | Verify `AdultModeManager.isAdultEnabled()` is checked in channel filter logic |
| Activation stuck | Confirm MAC address detection works (`MacAddressProvider`); test on real device if emulator fails |
| PIN dialog not appearing | PIN gating logic TODO in ChannelsActivity—implement before channel selection |

---

## Future Phases (Roadmap)
- **Phase 9**: Room/Datastore for Favorites; cloud sync hook
- **Phase 10**: Pluggable VPN provider (WireGuard/OpenVPN integration)
- **Phase 11**: Full EPG overlay; recording DVR module
- **Phase 12**: Security hardening (EncryptedSharedPreferences, obfuscation, remote config)

Refer to [MIGRATION_PLAN.md](MIGRATION_PLAN.md) for full spec.
