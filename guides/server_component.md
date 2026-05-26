# Server Component Guide

**Component:** Server Infrastructure (PHP/MySQL)
**Domain:** Backend, Ingest, API
**Topic:** Ingest Endpoints, Database, Governance
**Unit Type:** Server
**Created:** 2026-02-02

---

## Overview
The server infrastructure is PHP-based, running on shared hosting (miratv.club), and manages ingest endpoints, API, and MySQL persistence. It enforces token-protected ingest, parameterized SQL, and governance via multi-database architecture.

## Directory & Key Files
- **/public_html/** – Web root
  - `db_sql.php` – Database connection
  - `_ingest/import_epg.php` – EPG ingest (XMLTV → MySQL)
  - `_ingest/import_series_json.php` – Series ingest
  - `api/` – Xtream API endpoints
  - `activation_resolver.php` – Device binding
- **/AI_WORKERS/** – AI routing, provider integration
  - `router.php` – AI routing logic
  - `provider/open_ai.php` – OpenAI integration
  - `provider/cohere.php` – Cohere integration
  - `config/ai_config.php` – AI provider config

## Key Workflows
- **Ingest:** Token-protected POST to ingest endpoints
- **API:** Xtream endpoints for client data
- **Governance:** Multi-database enforcement, rule evaluation
- **AI Routing:** Config-driven provider selection

## Integration Points
- **MySQL:** Multi-database, parameterized SQL
- **PHP:** XMLReader, REST endpoints
- **AI Providers:** OpenAI, Cohere via config

## CVI/Registry Notes
- All server logic is modular, parameterized, and CVI-explicit for registry onboarding.
- See xpdgxfsp_* .sql files for schema.

---

## Actionable Onboarding
- Deploy: Upload PHP files to /public_html
- Configure: Set tokens in ingest endpoints
- Registry: All server modules are CVI-ready for PCDE_memory onboarding.
