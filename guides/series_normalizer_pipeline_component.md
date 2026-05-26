# Series Normalizer & Worker Guide

**Component:** Series Normalizer & Worker (PowerShell)
**Domain:** Content Normalization, Batch Processing
**Topic:** Series, Seasons, Episodes, MySQL Ingest
**Unit Type:** Batch Pipeline
**Created:** 2026-02-02

---

## Overview
The Series Normalizer pipeline ingests, normalizes, and uploads series, season, and episode data to the MySQL database. It consists of a main normalizer script and a queue-drain worker for continuous processing.

## Key Scripts
- `series_normalize.ps1` – Main normalizer, loads MySQL driver, fetches unparsed payloads, normalizes, and uploads
- `series_normalize_worker.ps1` – Worker script, runs the normalizer in a loop, handles errors, and manages queue draining

## Key Workflows
- Loads MySQL .NET driver for DB access
- Connects to `xpdgxfsp_content` as `xpdgxfsp_ingest`
- Fetches unparsed payloads from `series_details_raw`
- Normalizes and uploads parsed data
- Worker script manages retries, error thresholds, and clean exit

## Integration Points
- MySQL (xpdgxfsp_content)
- Upstream: Series grinder pipeline

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding
- Worker is queue-safe and error-tolerant

---

## Actionable Onboarding
- Run: Execute `series_normalize_worker.ps1` for continuous ingest
- Registry: All modules are CVI-ready for PCDE_memory onboarding
