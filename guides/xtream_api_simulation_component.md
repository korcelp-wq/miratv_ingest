# Xtream API Simulation Component: Location, Flow, and Integration

## Purpose
This guide documents the Xtream API simulation component, including its location, function, deployment, and integration with the MiraTV system.

---

## 1. Component Location
- **Directory:** c:/Android_Projects/MiraTV_project_PHASES_1_8/server_deploy/_workers/ai/
- **Key Files:**
  - xtream_api_gateway.php (main router)
  - xtream_api_handler.php (business logic)
  - xtream_db_config.php (DB config)
  - player_api.php (Xtream-compatible endpoint)
  - xtream_api_simulation_procedures.sql (stored procedures)
  - README.md (deployment guide)
  - USAGE_GUIDE.md, REFACTOR_GUIDE.md (how-to docs)

---

## 2. Function
- Exposes MySQL stored procedures as HTTP endpoints mimicking Xtream Codes API
- Supports live, VOD, and series queries for Android and other clients
- Handles authentication, routing, and business logic

---

## 3. Deployment & Configuration
- Update DB credentials in xtream_db_config.php
- Upload all files to public_html/_workers/ai/ or public_html/api/xtream/
- Deploy stored procedures to xpdgxfsp_content using xtream_api_simulation_procedures.sql
- Set file permissions (see README.md)

---

## 4. Supported Endpoints
- get_live_categories, get_live_streams, get_vod_categories, get_vod_streams, get_series_categories, get_series, get_series_info
- All endpoints accept GET or POST with username/password

---

## 5. Android Client Integration
- Set BASE_URL to https://miratv.club/_workers/ai/
- Use standard Xtream API actions in Retrofit or HTTP client

---

## 6. Security & Troubleshooting
- Use HTTPS in production
- Store DB config securely
- Enable rate limiting and IP restrictions as needed
- See README.md for troubleshooting common issues

---

## 7. Traceability
- All API calls are logged via PHP error log and (optionally) custom logging
- Stored procedures are versioned in xtream_api_simulation_procedures.sql

---

## 8. Contact
For API or deployment issues, contact the backend/API lead or system architect.
