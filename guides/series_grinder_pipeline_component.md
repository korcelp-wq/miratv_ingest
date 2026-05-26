# Series Grinder Pipeline Guide (Steps 1–7)

**Component:** Series Grinder Pipeline (PowerShell)
**Domain:** Content Extraction, Batch Processing
**Topic:** Series Metadata Extraction, File Processing
**Unit Type:** Batch Pipeline
**Created:** 2026-02-02

---

## Overview
The Series Grinder pipeline is a multi-step PowerShell batch process that extracts, normalizes, and cleans series metadata from raw provider payloads. Each step is a dedicated script, operating on files only (no DB writes), producing intermediate JSON artifacts for later ingestion.

## Key Scripts & Steps
- `series_grinder.ps1` – Extracts core series fields from raw payloads
- `series_grinder_2_series_ext.ps1` – Extracts extended series metadata
- `series_grinder_3_seasons.ps1` – Extracts season units by structure
- `series_grinder_4_season_ext.ps1` – Extracts extended season metadata
- `series_grinder_5_episodes.ps1` – Extracts episode units, supports fallback for season-keyed objects
- `series_grinder_6_cleaner.ps1` – Cleans up processed files and removes raw artifacts
- `series_grinder_7_finalizer.ps1` – (Empty/placeholder for future finalization)
- `series_grinder_arrays.ps1` – Handles array-based series payloads, repairs display wrapping

## Key Workflows
- Each script reads from `raw_store/pickup/default` and writes to `series_sep/`
- Extraction is anchor-based, not schema-based (brace/bracket block parsing)
- No DB access; all operations are file-based for safety and traceability
- Cleaning step removes all intermediate and raw artifacts

## Integration Points
- Downstream: Normalizer and ingest workers
- Upstream: Provider payload downloaders

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding
- Each step is independently runnable for debugging

---

## Actionable Onboarding
- Run: Execute each script in order for a full pipeline
- Registry: All modules are CVI-ready for PCDE_memory onboarding
