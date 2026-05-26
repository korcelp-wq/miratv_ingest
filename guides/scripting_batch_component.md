# Scripting & Batch Component Guide

**Component:** Scripting & Batch Automation
**Domain:** Ingest, Registry, Orchestration
**Topic:** PowerShell, Batch, Automation
**Unit Type:** Scripts
**Created:** 2026-02-02

---

## Overview
All batch and scripting logic for ingest, registry upload, and orchestration is implemented in PowerShell (.ps1) and BAT scripts. These automate EPG/content ingest, registry uploads, and pipeline orchestration.

## Directory & Key Files
- **C:/miratv_ingest/workers/** – Main worker scripts
  - `embedding_pipeline.ps1` – Embedding pipeline, registry upload
  - `upload_cvi_registry.ps1` – Minimal registry upload
  - `spine/` – Master scheduler
- **C:/miratv_ingest/triggers/** – Orchestration scripts
- **C:/miratv_ingest/state/** – State tracking
- **C:/miratv_ingest/reports/** – Audit logs

## Key Workflows
- **Ingest:** PowerShell scripts automate EPG/content ingest
- **Registry Upload:** Scripts POST guides to CVI endpoint (PCDE_memory)
- **Orchestration:** Triggers and spine scripts sequence pipeline stages
- **State Tracking:** `.last` files in state/ for progress

## Integration Points
- **CVI Endpoint:** Registry upload via dog_open.php
- **MySQL:** Parameterized SQL for registry writes
- **Audit:** All script actions are logged for traceability

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding.
- See pcde_procedure_registry_create.sql for schema.

---

## Actionable Onboarding
- Run: `powershell -File embedding_pipeline.ps1`
- Registry: All scripts are CVI-ready for PCDE_memory onboarding.
