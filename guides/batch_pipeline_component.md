# Batch Processing Component Guide

**Component:** Batch Processing Pipeline
**Domain:** Ingest, Normalization, Orchestration
**Topic:** Content Ingest, Series/Movie Processing
**Unit Type:** Pipeline
**Created:** 2026-02-02

---

## Overview
The batch processing pipeline automates ingest, normalization, and enrichment of IPTV content (live, VOD, series, EPG). It is orchestrated via PowerShell scripts, triggers, and workers, with state tracking and audit logging.

## Directory & Key Files
- **C:/miratv_ingest/raw/** – Raw provider downloads
- **C:/miratv_ingest/processed/** – Normalized/parsed content
- **C:/miratv_ingest/triggers/** – Orchestration scripts
- **C:/miratv_ingest/workers/** – Processing workers
- **C:/miratv_ingest/state/** – State tracking
- **C:/miratv_ingest/reports/** – Audit logs
- **C:/miratv_ingest/tmp/** – Temporary processing

## Key Workflows
- **Ingest:** Download provider data to raw/
- **Normalize:** Process/parse to processed/
- **Enrich:** Metadata extension, pattern reuse
- **Orchestrate:** Triggers and workers sequence stages
- **Track:** State and audit logs for traceability

## Integration Points
- **PowerShell:** All batch logic
- **MySQL:** Bulk inserts via ingest endpoints
- **Audit:** All actions logged

## CVI/Registry Notes
- All pipeline logic is modular and CVI-explicit for registry onboarding.
- See guides/embedding_pipeline_component.md for embedding details.

---

## Actionable Onboarding
- Run: `powershell -File triggers/your_trigger.ps1`
- Registry: All pipeline modules are CVI-ready for PCDE_memory onboarding.
