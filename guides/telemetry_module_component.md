# Telemetry Module Guide (PHP & PowerShell)

**Component:** Telemetry Module
**Domain:** Telemetry, Monitoring, Audit
**Topic:** Universal Telemetry, API & Batch
**Unit Type:** Telemetry
**Created:** 2026-02-02

---

## Overview
The telemetry module provides universal telemetry for all web endpoints (PHP) and batch scripts (PowerShell). It records job start, checkpoints, and completion, and can send events to a central telemetry endpoint.

## Key Files
- `shared/telemetry.php` – PHP telemetry class
- `shared/telemetry.ps1` – PowerShell telemetry module
- `telemetry/record.php` – Telemetry ingest endpoint (POST)
- `telemetry_config.json` – Config file

## Key Workflows
- Start telemetry at job/API start
- Record checkpoints and completion
- Send events to telemetry/record.php (with token)
- Events stored in xpdgxfsp_ops.job_events

## Integration Points
- All API endpoints and batch scripts
- MySQL (xpdgxfsp_ops)
- Telemetry ingest endpoint (record.php)

## CVI/Registry Notes
- All logic is modular and CVI-explicit for registry onboarding
- See telemetry_config.json for config

---

## Actionable Onboarding
- Deploy: Copy all files to server
- Configure: Set TELEMETRY_INGEST_TOKEN env var
- Registry: All modules are CVI-ready for PCDE_memory onboarding
