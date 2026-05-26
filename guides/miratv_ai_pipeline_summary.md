# MiraTV AI Knowledge Pipeline – Implementation Summary

## 1. What Was Built

This document summarizes the completed AI/LLM knowledge pipeline assembled during this chat.

---

## 2. Core Components

### A. Embedding Worker (`embed_worker.php`)
**Purpose**
- Pulls pending items from `embedding_queue`
- Reads text from:
  - `knowledge_units` (via `v_unit_text`)
  - `extracted_docs`
- Calls OpenAI Embeddings API
- Stores vectors in `embeddings`
- Logs lifecycle events in `ai_events`

**Status**
- ✅ Working
- ✅ Batch-limited
- ✅ Rate-limited
- ✅ Fully config-driven
- ✅ Token-gated by `.htaccess`

**Cost**
- Uses `text-embedding-3-large`
- Approx $0.13 / 1M tokens
- ~2k tokens per unit
- 1,000 units ≈ $0.26

---

### B. Link Refinement Worker (`refine_links.php`)
**Purpose**
- Reads existing embeddings
- Computes cosine similarity locally
- Creates/updates semantic relationships:
  - `knowledge_links`
  - topic associations
- Logs `refine` events in `ai_events`

**Cost**
- $0 API usage
- DB + CPU only

---

### C. Retry Worker (`retry_failed.php`)
**Purpose**
- Resets failed embedding jobs
- Logs retry events
- Hygiene / recovery tool

---

## 3. Configuration Architecture

All runtime values are externalized into config files.

### Config Files
- `_workers/ai/config/db.php`
- `_workers/ai/config/ai_config.php`
- `_workers/ai/config/ai.php`

**What lives in config**
- OpenAI API key
- Model selection
- Batch sizes
- Rate limits
- Similarity thresholds
- Retry limits

**What does NOT live in workers**
- Secrets
- Hardcoded constants
- Environment assumptions

---

## 4. Logging (`ai_events`)

Tracks:
- event_type (embedding, refine, retry)
- item_type (unit, artifact, system)
- item_id
- model
- status (started, success, error)
- timestamps

**Why it matters**
- Cost tracking
- Auditing
- Debugging
- Safe retries
- Model evolution history

---

## 5. Cron Model (Recommended)

```bash
# Embeddings (paid)
*/5 * * * * php _workers/ai/embed_worker.php

# Refinement (free)
*/15 * * * * php _workers/ai/refine_links.php
```

---

## 6. Query Architecture (Important)

### ❌ What NOT to do
- Do NOT compute cosine similarity in MySQL
- MySQL/MariaDB does not support vector math
- `COSINE_SIM()` does not exist

### ✅ Correct Flow
1. Embed user query (OpenAI)
2. Fetch candidate embeddings from DB
3. Compute cosine similarity in PHP
4. Apply `priority` weighting
5. Rank and return results

---

## 7. Priority Weighting

`knowledge_units.priority`
- Default: `1.0`
- Boosted by:
  - pinned parameters
  - master docs
  - admin signals

Final score example:
```php
$score = cosine($queryVec, $unitVec) * $priority;
```

---

## 8. Feeding Results into LLM (RAG)

**Important distinction**
- ❌ Embeddings are NOT uploaded into the LLM
- ✅ Retrieved text is passed as context

### RAG Flow
1. User query → embedding
2. Top-N `knowledge_units` selected
3. Prompt constructed with retrieved text
4. LLM called with grounded context

---

## 9. Current State

You now have:
- ✅ Structured document ingestion
- ✅ Section extraction
- ✅ Parameter normalization
- ✅ Embedding pipeline
- ✅ Semantic linking
- ✅ Priority signals
- ✅ AI event logging

You are **one endpoint away** from a full semantic query + answer system.

---

## 10. Next Logical Step

Build `query.php`:
- Embed query
- Rank knowledge units
- Assemble prompt
- Call LLM
- Return answer + citations
