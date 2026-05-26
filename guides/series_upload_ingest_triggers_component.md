# Series Upload & Ingest Triggers Guide

**Component:** Series Upload & Ingest Triggers (Batch)
**Domain:** Batch Processing, File Transfer
**Topic:** Series Upload, Ingest, Archive
**Unit Type:** Batch Files
**Created:** 2026-02-02

---

## Overview
These batch files automate the upload and ingest of processed series files to the server. They handle FTP upload, file movement, and archiving.

## Key Scripts
- `6upload_trigger.bat` – Uploads series_sep JSON files to server, moves to processed
- `3ingest_trigger.bat` – Uploads series_sep JSON files to server, moves to archive
- `upload_trigger2.bat` – Uploads raw_store JSON files to server, moves to processed
- `06_upload_trigger.bat` – Uploads series_sep JSON files to server, moves to processed

## Key Workflows
- FTP upload of processed files
- Move uploaded files to processed or archive
- Echo status for each file

## Integration Points
- FTP server (miratv.club)
- Processed and archive directories

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute relevant upload/ingest trigger as needed
- Registry: CVI-ready for PCDE_memory onboarding
