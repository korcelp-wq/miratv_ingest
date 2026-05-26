# Watcher CVI Client Guide

**Component:** Watcher CVI Client (PowerShell)
**Domain:** Batch Monitoring, CVI Coordination
**Topic:** Batch Execution Tracking, CVI Requests
**Unit Type:** Monitoring Script
**Created:** 2026-02-02

---

## Overview
The Watcher CVI client script monitors batch executions and posts coordination requests to the CVI endpoint. It tracks active jobs and submits context to the CVI system for each detected batch process.

## Key Script
- `watcher_cvi.ps1` – Monitors running batch jobs, posts to CVI endpoint

## Key Workflows
- Monitors running cmd processes
- Submits coordination requests to CVI for each new batch job
- Handles errors and logs request IDs

## Integration Points
- CVI endpoint (cvi_request.php)

## CVI/Registry Notes
- Modular and CVI-explicit for registry onboarding

---

## Actionable Onboarding
- Run: Execute to monitor and coordinate batch jobs
- Registry: CVI-ready for PCDE_memory onboarding
