# Human Operator & Onboarding Guide

**Component:** Human Operator & Onboarding
**Domain:** Operations, Documentation, Registry
**Topic:** Contributor Onboarding, Registry Upload, Authority
**Unit Type:** Human/Process
**Created:** 2026-02-02

---

## Overview
Human operators are responsible for onboarding, registry uploads, documentation, and authority adjudication. All automation, AI, and pipelines ultimately defer to human authority for canonization, escalation, and operational sign-off.

## Directory & Key Files
- **C:/miratv_ingest/guides/** – All component guides
- **C:/miratv_ingest/pcde_procedure_registry_create.sql** – Registry schema
- **C:/miratv_ingest/workers/upload_cvi_registry.ps1** – Registry upload script
- **LIVING_CONTEXT_SYSTEM.md** – System context
- **MIGRATION_PLAN.md** – Migration and onboarding plan

## Key Workflows
- **Onboarding:** Read all guides in guides/
- **Registry Upload:** Use upload_cvi_registry.ps1 or embedding_pipeline.ps1
- **Authority:** Human adjudication for canon rules, escalation, and registry sign-off
- **Documentation:** Maintain and update all guides for discoverability

## Integration Points
- **PowerShell:** Registry upload scripts
- **Markdown:** All guides in .md format
- **SQL:** Registry schema and onboarding

## CVI/Registry Notes
- All onboarding and authority processes are CVI-explicit for registry onboarding.
- See Contributor Onboarding section in copilot-instructions.md.

---

## Actionable Onboarding
- Read: All guides in guides/
- Upload: Use upload_cvi_registry.ps1 to register guides
- Authority: Human sign-off required for canonization and escalation
- Registry: All onboarding modules are CVI-ready for PCDE_memory onboarding.
