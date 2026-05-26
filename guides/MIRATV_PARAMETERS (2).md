# 📦 MIRATV — PARAMETERS (PRODUCTION BASELINE)

**Version:** 1.2  
**Status:** LOCKED / PRODUCTION  
**Scope:** Activation, Client Persistence, Invisible Login, Reactivation  
**Encoding:** UTF-8  

---

## 1️⃣ Core Principle

The system answers **two distinct questions**:

1. **Activation (miratv.club)**  
   → *Is this device (MAC) authorized and active?*

2. **Playback (Xtream / provider backend)**  
   → *Are the issued username/password valid?*

These concerns are **strictly separated**.

---

## 2️⃣ Device Identifier (MAC)

- Opaque identifier  
- Exact string match only  
- Derived from `ANDROID_ID`  
- Never regenerated  
- Never cleared (even after expiry)  

The MAC is the **permanent device anchor**.

---

## 3️⃣ Activation API (Authoritative)

### Endpoint
```
POST https://miratv.club/activation_resolver.php?fn=auth
```

### Request (JSON)
```json
{
  "code": "K6HH4CMJ",
  "mac": "b89c4ca314f9f32e",
  "device_fingerprint": "b89c4ca314f9f32e"
}
```

**Rules**
- Either `code` or `mac` must be provided  
- `device_fingerprint` is used for binding and validation  
- `Content-Type: application/json`  

---

### Successful Response
```json
{
  "status": "ok",
  "dns": "miratv.club",
  "username": "Marina2025",
  "password": "DJUNDAAV",
  "expires": "2026-01-16",
  "bound_to": "b89c4ca314f9f32e"
}
```

### Failure Responses (examples)
```json
{ "ok": false, "status": "expired" }
{ "ok": false, "status": "blocked" }
{ "ok": false, "error": "provide code or mac" }
```

Activation logic is **SQL-backed** and authoritative.

---

## 4️⃣ Client Storage Requirements (Mandatory)

Upon **successful activation only**, the app must persist:

### Activation Inputs
- `mac`
- `code`
- `device_fingerprint`

### Credentials (from API)
- `username`
- `password`
- `expires`

### Service Metadata
- `dns`
- `bound_to`

### Metadata
- `activated_at` (client timestamp)
- `last_verified_at` (optional)

**Rules**
- Data is written atomically (all or nothing)  
- No partial writes  
- Persists across:
  - app restarts
  - device reboots
  - background kills  
- MAC is **never cleared**  
- Credentials are cleared **on expiry only**  

---

## 5️⃣ Invisible Login Behavior

On app launch:

1. Check local storage for:
   - `username`
   - `password`
   - `expires`
2. If credentials exist **and** `now < expires`:
   - Perform automatic login  
   - No user interaction  
   - No activation call  

This is considered **invisible login**.

---

## 6️⃣ Reactivation Behavior

If credentials are missing or expired:

1. Check stored:
   - `mac`
   - `device_fingerprint`
   - last activation `code` (if available)
2. Activation UI may be pre-filled  
3. Reactivation call uses:
```json
{
  "mac": "...",
  "device_fingerprint": "..."
}
```

On success:
- New credentials overwrite old  
- Expiry updated  
- Activation metadata refreshed  

---

## 7️⃣ Failure Handling

If activation fails:

- No stored data is overwritten  
- No credentials stored  
- MAC remains intact  
- User must retry manually  

---

## 8️⃣ Export Requirements (Debug / Support)

The app must support **on-demand export** of:

- Activation request payload  
- Activation response payload  
- Current stored values (sanitized if needed)  

**Format**
- Plain text (`.txt`)  
- UTF-8  
- Human-readable  
- No binary encoding  

Used for:
- diagnostics  
- support  
- migration  
- forensic analysis  

---

## 9️⃣ Security & Binding

- Credentials are device-specific  
- `bound_to` must match current device  
- Any mismatch → reactivation required  
- Export requires explicit user action  

---

## 🔒 10️⃣ Environment & Code Boundaries (Locked)

**Non-negotiable rules:**

```
UI files:
  - include config.php ONLY

API files:
  - include db_sql.php ONLY

They never include each other.
```

---

## 📌 Design Intent

This system is:

- zero-friction for users  
- resilient to network failures  
- deterministic across restarts  
- cleanly separable (activation vs playback)  
- ready for AI-assisted logic layers  

---

## 🧠 Authoritative Note

These parameters define the **core contract**.

Any future refactor must preserve:
- stored activation data  
- invisible login behavior  
- safe reactivation  
- export capability  
