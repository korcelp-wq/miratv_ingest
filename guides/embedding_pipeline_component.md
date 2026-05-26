# Embedding Pipeline Component: Location, Flow, and Integration

## Purpose
This guide documents the embedding pipeline component, including its location, function, database integration, and how it fits into the MiraTV system.

---

## 1. Component Location
- **Script:** c:/miratv_ingest/workers/embedding_pipeline.ps1
- **Related scripts:** co-located in /miratv_ingest/workers/
- **Batch entrypoints:** run_pipeline.ps1, run_series_pipeline.ps1

---

## 2. Function
- Batch embeds pending text entries using Cohere API
- Stores vector embeddings in lake_vector and i_m_g_vector_context databases
- Enables semantic search and downstream AI workflows
- Records telemetry for each run

---

## 3. Database Integration
- **Target DBs:** lake_vector, i_m_g_vector_context
- **Stored Procedures Used:**
  - sp_get_pending_embeddings (fetches pending items)
  - sp_store_embedding (stores embedding vectors)
- **Registry Upload:**
  - Uploads pipeline instructions and metadata to PCDE_memory/pcde_procedure_registry via CVI (Dog_open.php)

---

## 4. Flow Overview
1. Fetch pending embeddings from DB
2. Batch embed with Cohere
3. Store results in DB
4. Upload registry entry (CVI)
5. Record telemetry

---

## 5. Key Files
- embedding_pipeline.ps1 (main logic)
- telemetry.ps1 (shared telemetry module)
- pcde_procedure_registry_create.sql (registry schema)

---

## 6. Traceability
- All runs are logged via telemetry
- Registry entries are discoverable in PCDE_memory
- All DB access is parameterized and auditable

---

## 7. Contact
For pipeline or integration issues, contact the AI/automation lead or system architect.
