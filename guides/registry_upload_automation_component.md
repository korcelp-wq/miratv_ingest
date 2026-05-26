# Registry Upload Automation Scripts Guide

**Component:** Registry Upload Automation (PowerShell)
**Domain:** Registry, Documentation, Automation
**Topic:** PCDE_memory, CVI, Embedding Pipeline
**Unit Type:** Automation Scripts
**Created:** 2026-02-02

---

## Overview
These PowerShell scripts automate the upload of documentation and pipeline instructions to the PCDE_memory registry via the Dog_open.php endpoint. They support parameterized SQL, CVI, and embedding pipeline metadata.

## Key Scripts
- `upload_pcde_registry.ps1` – Uploads a guide or doc to the registry (parameterized, generic)
- `upload_embedding_pipeline_registry.ps1` – Uploads embedding pipeline metadata (vector counts, provenance, etc.)
- `upload_cvi_registry.ps1` – Uploads CVI registry instructions (governance, provenance, status)

## Key Workflows
- Read .md or .txt doc, POST to Dog_open.php with token and metadata
- Parameterized SQL for all writes
- All actions are logged and auditable

## Integration Points
- PCDE_memory registry (Dog_open.php)
- Embedding pipeline scripts

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding
- Use for any registry doc or embedding pipeline upload

---

## Actionable Onboarding
- Run: Execute with required parameters (token, file, process name, etc.)
- Registry: All modules are CVI-ready for PCDE_memory onboarding
