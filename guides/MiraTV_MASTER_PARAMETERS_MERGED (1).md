# 📺 MiraTV — Activation, Login & App Flow (AUTHORITATIVE PARAMETERS)

**Status:** LOCKED / SOURCE OF TRUTH  
**Scope:** Android App + Backend Contract  
**Last Verified:** Prod (miratv.club)

---

## 1️⃣ Core Principles (Non-Negotiable)

### MAC / Device ID

- “MAC” is an **opaque identifier**
- NOT required to be a real hardware MAC
- Implemented as:
  - `ANDROID_ID` (or closest stable device identifier)
- Treated as:
  - Exact string match
- Stored permanently client-side
- Entered manually in backend when provisioning customer
- Backend does **no derivation**, only comparison

> The backend trusts the string.  
> The client never re-generates or mutates it.

---

## 2️⃣ App Startup Flow — **Splash → Activation → Provider Login → Home**

### 🔹 Splash Screen (Every Launch)

**Purpose**
- Visual startup
- Local session validation
- Routing decision only

**Logic**
```
App Launch
 └─ SplashScreenActivity
     ├─ Read SessionManager
     │   ├─ mac (device_id)
     │   ├─ username
     │   ├─ password
     │   ├─ expiry
     │   └─ base_url
     │
     ├─ If ANY missing → ActivationActivity
     ├─ If expired → clear credentials → ActivationActivity
     └─ Else → Provider Login
```

**Splash does NOT**
- Make network calls
- Talk to miratv.club
- Talk to IPTV provider
- Regenerate MAC
- Modify session state

---

## 3️⃣ Activation Flow (FIRST-TIME / RECOVERY)

### Entry Point
`ActivationActivity`

### When Shown
- First install
- Session cleared
- Subscription expired
- MAC not recognized backend-side

### Backend Endpoint (ONLY)
```
GET https://miratv.club/api.php?fn=auth
```

#### Activation via CODE
```
GET /api.php?fn=auth&code=AB12CD34
```

#### Activation via MAC (re-bind / recovery)
```
GET /api.php?fn=auth&mac=00:11:22:33:44:55
```

### ✅ Successful Response
```json
{
  "ok": true,
  "status": "active",
  "dns": "eldervpn.xyz",
  "username": "USER123",
  "password": "PASS123",
  "expires": "2026-01-13",
  "bound_to": "00:11:22:33:44:55"
}
```

### ❌ Failure Responses
```json
{ "ok": false, "reason": "invalid_credentials" }
{ "ok": false, "reason": "account_expired" }
{ "ok": false, "reason": "mac_not_associated" }
```

### Client Rules
- ONLY save session on `ok:true`
- Store:
  - mac
  - username
  - password
  - expiry
  - base_url (from `dns`)
- NEVER overwrite MAC
- NEVER cache failure responses

After success:
```
Activation → Save Creds → Provider Login
```

---

## 4️⃣ Provider Login (AUTHENTICATION ≠ PLAYBACK)

### Purpose
Validate IPTV credentials and load metadata.  
**No media is accessed here.**

### Handshake Endpoint (Xtream-style)
```
GET https://{base_url}/player_api.php
  ?username=USER123
  &password=PASS123
```

### Expected Provider Response
```json
{
  "user_info": {
    "status": "Active",
    "exp_date": "1768272000",
    "is_trial": "0"
  },
  "server_info": {
    "url": "eldervpn.xyz",
    "port": "80"
  }
}
```

### Provider Login Rules
- Happens after activation OR valid splash resume
- MUST succeed before loading categories
- If invalid or expired:
  - Clear username/password/base_url
  - Keep MAC
  - Route to ActivationActivity

---

## 5️⃣ Home Screen Definition

🏠 **Home = Categories**  
`CategoriesActivity`

**Why**
- Matches IPTV mental model
- Previously working behavior
- Eliminates redundant Home screen

---

## 6️⃣ Category & Metadata Load (NO PLAYBACK)

### Categories
```
GET https://{base_url}/player_api.php
  ?username=USER123
  &password=PASS123
  &action=get_live_categories
```

### Streams (metadata only)
```
GET https://{base_url}/player_api.php
  ?username=USER123
  &password=PASS123
  &action=get_live_streams
```

⚠️ No `.ts` URLs here.

---

## 7️⃣ Playback (USER ACTION ONLY)

### Trigger
- User selects a channel
- PlayerActivity is active

### Stream URL Pattern
```
https://{base_url}/live/{username}/{password}/{stream_id}.ts
```

### PlayerActivity Rules
- MUST check SessionManager before playback
- MUST fail gracefully if credentials missing
- MUST NOT trigger activation directly
- MUST NOT be used as a login or health-check

---

## 8️⃣ SessionManager — Storage Contract

### Stored Permanently
| Key | Description |
|---|---|
| mac | ANDROID_ID / opaque device identifier |

### Stored Conditionally (`ok:true`)
| Key | Description |
|---|---|
| username | IPTV username |
| password | IPTV password |
| base_url | Provider base (e.g. eldervpn.xyz) |
| expiry | Subscription expiration |

### Expiry Handling
```
If expiry < today
 → Clear username/password/base_url
 → Keep MAC
 → ActivationActivity
```

---

## 9️⃣ What Is NOT Required (Yet)

❌ POST /api.php?fn=device/register  
❌ JSON POST bodies  
❌ Authorization headers  
❌ Device fingerprinting beyond MAC  
❌ Push / FCM / notifications  

These are future features, **not part of activation or login**.

---

## 🔟 Hosting Constraints (Important)

- Shared hosting (LiteSpeed / cPanel)
- `php://input` NOT reliable
- JSON POST bodies often stripped

✅ INLINE QUERY PARAMETERS REQUIRED

```
/api.php?fn=auth&code=XXXX
```

---

## 1️⃣1️⃣ Correct Test Commands

```bash
curl "https://miratv.club/api.php?fn=auth&code=TESTCODE123"
```

```bash
curl "https://miratv.club/api.php?fn=auth&mac=AA:BB:CC:DD:EE:FF"
```

```bash
curl "https://eldervpn.xyz/player_api.php?username=USER123&password=PASS123"
```

---

## 🔐 Final Guarantees

- No activation loops
- No premature playback
- No silent provider failures
- No MAC confusion
- Deterministic startup routing

**This document supersedes all previous parameter docs.**
