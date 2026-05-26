# Series Grinder Master Trigger Guide

**Component:** Series Grinder Master Trigger (Batch)
**Domain:** Batch Processing, Orchestration
**Topic:** Pipeline Trigger, Series Extraction
**Unit Type:** Batch File
**Created:** 2026-02-02

---

## Overview
The Series Grinder master trigger batch file orchestrates the full multi-step series extraction pipeline. It sequentially calls each PowerShell grinder step, waits for IO, and marks completion.

## Key Script
- `series_grinder_trigger.bat` – Calls all grinder steps (1–6), waits for IO, marks pipeline complete

## Key Workflows
- Sequentially calls each grinder step via PowerShell
- Waits for IO to settle
- Marks each step and pipeline as complete

## Integration Points
- Series grinder PowerShell scripts

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute to process all series extraction steps in order
- Registry: CVI-ready for PCDE_memory onboarding
