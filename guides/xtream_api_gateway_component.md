# Xtream API Gateway Guide

**Component:** Xtream API Gateway (PHP)
**Domain:** API Simulation, IPTV
**Topic:** Xtream API, Stored Procedures, Android Client
**Unit Type:** API Gateway
**Created:** 2026-02-02

---

## Overview
The Xtream API Gateway simulates the Xtream Codes API for the Android client, routing requests to stored procedures in the IPTV database. It supports all major Xtream actions (live, VOD, series) and is a drop-in replacement for player_api.php.

## Key Files
- `player_api.php` – Entry point, includes gateway
- `xtream_api_gateway.php` – Main API router, parses action/params, calls handler
- `xtream_api_handler.php` – Business logic, calls stored procedures
- `xtream_db_config.php` – DB connection/config, procedure call helper
- `xtream_api_simulation_procedures.sql` – All stored procedures for simulation

## Key Workflows
- Accepts GET/POST with username, password, action
- Validates credentials, routes to handler
- Handler calls stored procedures (e.g., sp_xtream_get_live_categories)
- Results returned as JSON, matching Xtream API spec

## Integration Points
- Android client (Retrofit Xtream endpoints)
- MySQL (xpdgxfsp_content)
- Telemetry module for API usage

## CVI/Registry Notes
- All logic is modular and CVI-explicit for registry onboarding
- See xtream_api_simulation_procedures.sql for procedure details

---

## Actionable Onboarding
- Deploy: Copy all files to server
- Configure: Update DB credentials in xtream_db_config.php
- Registry: All modules are CVI-ready for PCDE_memory onboarding
