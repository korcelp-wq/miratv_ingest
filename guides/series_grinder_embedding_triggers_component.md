# Series Grinder Trigger & Embedding On-Demand Guide

**Component:** Series Grinder Trigger & Embedding On-Demand (PowerShell)
**Domain:** Batch Processing, Embedding
**Topic:** Series Extraction, Embedding Pipeline
**Unit Type:** Trigger Scripts
**Created:** 2026-02-02

---

## Overview
These scripts trigger the series grinder pipeline and on-demand embedding. They orchestrate batch extraction and embedding for downstream processing.

## Key Scripts
- `series_grinder_trigger.ps1` – Triggers the series grinder pipeline
- `run_embedding_on_demand.ps1` – Triggers embedding pipeline for a target DB and batch size

## Key Workflows
- Call grinder or embedding pipeline scripts
- Pass parameters for target DB and batch size
- Output status and completion

## Integration Points
- Series grinder pipeline
- Embedding pipeline

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute to trigger series grinder or embedding on demand
- Registry: CVI-ready for PCDE_memory onboarding
