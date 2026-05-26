# MiraTV API Parameters – Activation & Auth (PROD)

> **Status:** ✅ VERIFIED WORKING IN PROD (shared hosting)  
> **Important:** Due to hosting/WAF behavior, **request bodies may be stripped**. Activation/login MUST support query parameters.

---

## 🔑 Activation Endpoint (SOURCE OF TRUTH)

**Endpoint**
```
/api.php?fn=auth
```

**Method**
```
GET (preferred)
POST also works IF parameters are passed via query string (no body required)
```

**Authentication**
- ✅ Public bootstrap endpoint for activation/login
- ❌ No API key required for `fn=auth`
- ❌ No Authorization header required for `fn=auth`
- 🔒 Other endpoints require API key (see below)

---

## 📥 Request Parameters (QUERY STRING)

### Option A — Activation Code (primary)
```
code=<ACTIVATION_CODE>
```

**Example**
```
https://miratv.club/api.php?fn=auth&code=JR55KCDB
```

---

### Option B — MAC Address (LOGIN / RE-AUTH)
```
mac=<MAC_ADDRESS>
```

**Example**
```
https://miratv.club/api.php?fn=auth&mac=73:3A:99:4E:C6:AA
```

**Purpose**
- Used for **post-activation login**
- Used for **auto-login on app relaunch**
- Used for **session recovery** (no code re-entry)

---

## 📤 Successful Response (ACTIVE)

### Response via Activation Code
```json
{
  "ok": true,
  "status": "active",
  "dns": "uxurwymd.eldervpn.xyz",
  "username": "Marina2025",
  "password": "DJUNDAAV",
  "m3u_link": "http://uxurwymd.eldervpn.xyz/get.php?username=Marina2025&password=DJUNDAAV&type=m3u_plus&output=mpegts",
  "expires_at": "2026-10-05"
}
```

### Response via MAC Login
```json
{
  "ok": true,
  "status": "active",
  "m3u_link": "http://uxurwymd.eldervpn.xyz/get.php?username=Marina2025&password=DJUNDAAV&type=m3u_plus&output=mpegts",
  "expires_at": null
}
```

### Client Handling Rules
- **Activation flow**: persist `dns`, `username`, `password`, `expires_at`
- **MAC login flow**: reuse stored credentials; `expires_at=null` means lookup-based
- If MAC login returns `ok:true`, **skip activation UI entirely**

---

## ⚠️ Failure Responses

### Expired
```json
{
  "ok": false,
  "status": "expired",
  "expires_at": "2026-10-05"
}
```

### Unregistered
```json
{
  "ok": false,
  "status": "unregistered",
  "message": "Code not found"
}
```

### Invalid Request
```json
{
  "ok": false,
  "error": "provide code or mac"
}
```

---

## 🧠 Hosting Constraint (CRITICAL)

Observed on current host:
- `application/json` POST bodies may be **stripped** by host/WAF
- `php://input` may be empty
- `$_POST` may be empty

✅ **Only reliable transport (verified):** Query parameters (`$_GET`) for activation/login.

---

## 🔒 API Key Policy (Post-Activation)

All non-activation endpoints **require API key**.

Header options:
- `X-API-Key: <key>`
- `Authorization: Bearer <key>`

Activation/login (`fn=auth`) is explicitly exempt.

---

## 📌 Android Integration Notes

- Use GET request for activation/login:
  - `fn=auth&code=...` for first activation
  - `fn=auth&mac=...` for auto-login/re-auth
- No request body
- No Authorization header needed for `fn=auth`
- Parse JSON response exactly as shown above
