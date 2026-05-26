# Spool Uploader & AI SQL Trigger Guide

**Component:** Spool Uploader & AI SQL Trigger (PowerShell)
**Domain:** Spool Upload, AI Coordination
**Topic:** Spool Upload, Open SQL, CVI
**Unit Type:** Utility Scripts
**Created:** 2026-02-02

---

## Overview
These scripts automate spool uploads and AI SQL coordination. They support one-shot uploads and parameterized SQL via the Dog_open.php endpoint.

## Key Scripts
- `upload_spool_once.ps1` – One-shot uploader for ops/lake/igm spools
- `trigger_ai_open_sql.ps1` – Parameterized SQL trigger for AI/Open SQL

## Key Workflows
- Upload spool log lines to CVI endpoint
- Move processed files to processed directory
- Trigger parameterized SQL via Dog_open.php

## Integration Points
- CVI endpoint (cvi_request.php)
- Dog_open.php endpoint

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute to upload spools or trigger AI SQL
- Registry: CVI-ready for PCDE_memory onboarding
