# Lake, Ops, IMG Upload Triggers Guide

**Component:** Lake, Ops, IMG Upload Triggers (Batch)
**Domain:** Batch Processing, File Transfer
**Topic:** Spool Upload, FTP, Telemetry
**Unit Type:** Batch Files
**Created:** 2026-02-02

---

## Overview
These batch files automate the upload of spool files (lake, ops, img) to the server via FTP. They ensure directory existence, move files to temp, upload, and handle retries.

## Key Scripts
- `lake_upload_trigger.bat` – Uploads lake spool files
- `ops_upload_trigger.bat` – Uploads ops spool files
- `img_upload_trigger.bat` – Uploads img spool files

## Key Workflows
- Ensure temp and done directories exist
- Move new files to temp, upload via FTP
- Handle upload errors and retries
- Move uploaded files to processed

## Integration Points
- FTP server (miratv.club)
- Spool directories (lake_spool, ops_spool, igm_spool)

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding
- Use for any spool upload pipeline

---

## Actionable Onboarding
- Run: Execute the relevant upload trigger .bat file
- Registry: All modules are CVI-ready for PCDE_memory onboarding
