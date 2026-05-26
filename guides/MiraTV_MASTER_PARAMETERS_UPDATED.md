# 📺 MiraTV — Activation, Login & App Flow  
**AUTHORITATIVE PARAMETERS (UPDATED)**

**Status:** LOCKED / SOURCE OF TRUTH  
**Scope:** Android App + Backend Contract  
**Effective:** Current  

---

## 1️⃣ Core Principles (Non-Negotiable)

### Device / MAC Identifier
- Treated as an **opaque, stable device identifier**
- Implemented via ANDROID_ID (or equivalent)
- Backend performs **exact string match only**
- Client never regenerates or mutates this value

---

## 2️⃣ Startup Flow (Splash → Activation → Home)

### SplashActivity
- Plays branded MP4 splash (~8 seconds)
- Reads local session only
- May perform **silent provider preflight**
- Exits exactly once

Routing:
- No local credentials → ActivationActivity
- Local credentials + provider OK → CategoriesActivity
- Local credentials + provider FAIL → ActivationActivity

---

## 3️⃣ Splash Screen — Silent Provider Preflight

### Purpose
During splash playback, the app MAY perform a single, read-only provider
authentication check to optimize routing.

### Allowed
- Local credential checks
- ONE provider request
- Logging and telemetry
- In-memory decision flags

### Not Allowed
- No backend calls (miratv.club)
- No provisioning or MAC recovery
- No retries or polling
- No state mutation

### Provider Endpoint
```
GET /player_api.php?username={u}&password={p}
```

HTTP 200 → accepted  
HTTP 401/403 → rejected

---

## 4️⃣ Activation Flow (Backend Authority)

### Endpoint
```
GET https://miratv.club/api.php?fn=auth
```

### Methods
- Code-based activation
- MAC-based recovery (reinstall)

Backend is the **sole source of truth** for activation.

---

## 5️⃣ SessionManager Storage Contract

### Persistent
- mac / device_id

### Conditional (ok:true)
- username
- password
- base_url
- expiry

Expired sessions are cleared locally (MAC retained).

---

## 6️⃣ Home Definition

🏠 Home = CategoriesActivity  
This is final.

---

## 7️⃣ Provider Authentication & Playback

- Provider domain (e.g. eldervpn.xyz)
- Username + password only
- No MAC usage provider-side

Playback pattern:
```
/live/{username}/{password}/{stream_id}.ts
```

---

## 8️⃣ Hosting Constraints

- Shared hosting (LiteSpeed / cPanel)
- Query-string parameters required
- JSON POST bodies unreliable

---

## 🔐 Invariant

> The splash screen may observe network truth, but must never become a source of truth.

---

### ✅ This document is sufficient to resume development in a new chat.
