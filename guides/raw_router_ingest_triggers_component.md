# Raw Router & Ingest Triggers Guide

**Component:** Raw Router & Ingest Triggers (PowerShell)
**Domain:** Batch Processing, Ingest
**Topic:** Raw Routing, Ingest Trigger
**Unit Type:** Trigger Scripts
**Created:** 2026-02-02

---

## Overview
These scripts trigger raw router and ingest operations. They orchestrate the movement and ingestion of raw payloads for downstream processing.

## Key Scripts
- `raw_router_trigger.ps1` – Triggers raw router worker
- `raw_ingest_trigger2.ps1` – Triggers raw ingest via web request

## Key Workflows
- Call raw router worker script
- Trigger ingest via web request with token

## Integration Points
- Raw router worker
- Ingest web endpoint

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute to trigger raw router or ingest
- Registry: CVI-ready for PCDE_memory onboarding
