# Batch File Orchestration Guide (DB Grinder & Upload)

**Component:** DB Grinder & Upload Orchestration (Batch)
**Domain:** Batch Processing, File Transfer, Telemetry
**Topic:** Raw Data Copy, FTP Upload, Telemetry
**Unit Type:** Batch Files
**Created:** 2026-02-02

---

## Overview
These batch files orchestrate the copying, uploading, and telemetry reporting for the DB grinder pipeline. They automate raw data movement, FTP uploads, and telemetry event posting.

## Key Scripts
- `db_grinder_worker.bat` – Copies raw input, calls upload trigger, posts telemetry
- `db_grinder_upload_trigger.bat` – Uploads processed files via FTP, posts telemetry

## Key Workflows
- Copy raw input to working directory
- Call upload trigger for FTP transfer
- Post telemetry events to API endpoint
- Error handling and status reporting

## Integration Points
- FTP server (miratv.club)
- Telemetry API (telemetry_component.php)

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding
- Use for any DB grinder or batch upload pipeline

---

## Actionable Onboarding
- Run: Execute worker .bat file with run ID
- Registry: All modules are CVI-ready for PCDE_memory onboarding
