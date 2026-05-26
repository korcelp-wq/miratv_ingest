# 

MIRATV — PROJECT PARAMETERS (LOCKED + EXPANDED)



Version: 1.2

Status: LOCKED BASELINE + CLARIFICATIONS

Last Updated: 2025-12-13



CORE PRINCIPLE

The app answers TWO separate questions:

1) Activation (miratv.club) — Is this MAC active?

2) Playback (Xtream) — Are username/password valid?



DEVICE IDENTIFIER (MAC)

- Opaque identifier

- Exact string match only

- Derived from ANDROID_ID

- Never regenerated



ACTIVATION FLOW

- First run only

- Screen never auto-dismisses

- Activation success stores credentials + expiry

- Failure stores nothing



PLAYBACK FLOW

- Username + password only

- MAC never sent to playback backend



SESSION RULES

- Store data only on successful activation

- Clear credentials on expiry

- Preserve MAC always



NETWORK

- miratv.club → activation

- eldervpn.xyz → playback

