# Test & Utility Scripts Guide

**Component:** Test & Utility Scripts (PowerShell)
**Domain:** Testing, Utility, Automation
**Topic:** Script Testing, Registry Upload
**Unit Type:** Utility Scripts
**Created:** 2026-02-02

---

## Overview
Test and utility scripts support development, testing, and registry upload automation. They include test scripts and minimal uploaders for rapid iteration.

## Key Scripts
- `test.ps1` – Minimal test script for PowerShell
- `upload_cvi_registry.ps1` – Minimal CVI registry uploader

## Key Workflows
- Run test.ps1 to validate PowerShell environment
- Use upload_cvi_registry.ps1 for quick registry uploads

## Integration Points
- PCDE_memory registry (Dog_open.php)

## CVI/Registry Notes
- All scripts are modular and CVI-explicit for registry onboarding
- Use for testing and rapid registry automation

---

## Actionable Onboarding
- Run: Execute test.ps1 or upload_cvi_registry.ps1 as needed
- Registry: All modules are CVI-ready for PCDE_memory onboarding
