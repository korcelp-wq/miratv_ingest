# Device Activation & IP Database Component: Location, Flow, and Integration

## Purpose
This guide documents the device activation and IP database component, including its location, schema, and integration in the MiraTV system.

---

## 1. Component Location
- **Schema File:** c:/Android_Projects/MiraTV_project_PHASES_1_8/xpdgxfsp_ip.sql
- **Database Name:** xpdgxfsp_ip
- **Key Tables:**
  - activation_codes
  - mac_users
  - device_tokens
  - admins
  - account_profile
  - ai_memory_index

---

## 2. Function
- Stores device activation codes and MAC address bindings
- Manages user/device authentication and status
- Tracks device tokens and admin accounts
- Supports AI memory index for cross-component knowledge

---

## 3. Integration Points
- Used by activation endpoints and admin tools
- Referenced by Android client for device activation and login
- Integrated with server-side PHP for account management

---

## 4. Traceability
- All device activations and status changes are auditable
- Table changes are versioned in xpdgxfsp_ip.sql

---

## 5. Related Files
- xpdgxfsp_ip.sql (schema)
- ActivationApi.kt, ActivationApiClient.kt (Android client)
- activation_resolver.php (server, if present)

---

## 6. Contact
For activation or IP DB issues, contact the system architect or device onboarding lead.
