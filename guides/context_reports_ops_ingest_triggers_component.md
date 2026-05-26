# Context Reports & Ops Ingest Triggers Guide

**Component:** Context Reports & Ops Ingest Triggers (PowerShell)
**Domain:** Reporting, Ingest
**Topic:** Context Publishing, Ops Log Ingest
**Unit Type:** Trigger Scripts
**Created:** 2026-02-02

---

## Overview
These scripts automate the publishing of context reports and ingestion of ops logs. They support scheduled and on-demand publishing, as well as ops log ingestion via web request.

## Key Scripts
- `publish_context_reports.ps1` – Publishes formatted context reports for review
- `ops_ingest_trigger.ps1` – Triggers ops log ingestion via web request

## Key Workflows
- Publish context reports for all or specific components
- Trigger ops log ingestion with token

## Integration Points
- Context report stored procedures
- Ops ingest web endpoint

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute to publish context or ingest ops logs
- Registry: CVI-ready for PCDE_memory onboarding
