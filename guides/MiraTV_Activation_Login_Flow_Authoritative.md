# 📺 MiraTV — Activation, Login & Provider Handshake (AUTHORITATIVE PARAMETERS)

Status: LOCKED / SOURCE OF TRUTH  
Scope: Android App + Backend Contract  
Last Verified: Prod (miratv.club)

---

## 1️⃣ Core Principles (Non‑Negotiable)

### MAC / Device ID

- “MAC” is an opaque identifier
- NOT required to be a real hardware MAC
- Implemented as ANDROID_ID (or closest stable device identifier)
- Treated as exact string match
- Stored permanently client‑side
- Entered manually in backend when provisioning customer
- Backend does no derivation, only comparison

The backend trusts the string.  
The client never re‑generates or mutates it.

---

## 2️⃣ App Startup Flow — Splash → Activation → Provider Login → Home

### Splash Screen (Every Launch)

Purpose:
- Visual startup
- Local session validation
- Routing decision only

Logic:
App Launch  
→ SplashScreenActivity  
→ Read SessionManager (mac, username, password, expiry, base_url)

Decision:
- If ANY missing → ActivationActivity
- If expired → clear creds → ActivationActivity
- Else → Provider Login

Splash MUST NOT:
- Make network calls
- Talk to miratv.club
- Talk to IPTV provider
- Regenerate MAC
- Modify session state

---

## 3️⃣ Activation Flow (First‑Time / Recovery)

Endpoint:
GET https://miratv.club/api.php?fn=auth

Activation via Code:
GET /api.php?fn=auth&code=AB12CD34

Activation via MAC:
GET /api.php?fn=auth&mac=00:11:22:33:44:55

Successful Response:
{
  "ok": true,
  "status": "active",
  "dns": "eldervpn.xyz",
  "username": "USER123",
  "password": "PASS123",
  "expires": "1768272000",
  "bound_to": "00:11:22:33:44:55"
}

---

## 4️⃣ Provider Login (Authentication ≠ Playback)

Handshake:
GET https://{base_url}/player_api.php?username=USER123&password=PASS123

Purpose:
- Validate credentials
- Load metadata
- NO media access

---

## 5️⃣ Home Screen

Home = CategoriesActivity

---

## 6️⃣ Category & Metadata Load

Categories:
GET player_api.php?action=get_live_categories

Streams metadata:
GET player_api.php?action=get_live_streams

No .ts access here.

---

## 7️⃣ Playback (User Action Only)

GET https://{base_url}/live/{username}/{password}/{stream_id}.ts

---

## 8️⃣ SessionManager Contract

Persistent:
- mac

Conditional:
- username
- password
- base_url
- expiry

Expiry clears creds, not MAC.

---

## Final Guarantees

No activation loops  
No premature playback  
Deterministic routing  
Single source of truth
