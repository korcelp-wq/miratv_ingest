<!--
COPILOT INSTRUCTIONS (READ CAREFULLY):

You are generating a CONTEXTUAL SUMMARY for ONE SYSTEM COMPONENT.

DO:
- Describe intent, pressure, goals, blind spots
- Use plain language
- Leave unknowns explicit

DO NOT:
- Propose solutions
- Invent metrics
- Write code
- Make decisions
- Use theory language

This file is a SITUATIONAL SNAPSHOT, not a design doc.

Component: Android Client (MiraTV app, Phases 1-8)
-->

# Contextual Summary — Android Client

## Component Role

Live TV, VOD, and series streaming app for Android. Activation via MAC address. Session management (username/password). Xtream API client (Retrofit). ExoPlayer HLS playback. RecyclerView shelves. Parental PIN (scaffolded). Adult mode toggle. Favorites (local, not synced).

## Current Intent

Provide smooth IPTV experience on TVs (Leanback-compatible). Auto-activate via device identity (MAC). Support Live, VOD, Series browse/search. Stream HLS without credentials stored on device. Respect parental controls.

## Operating Mode

SplashActivity → ActivationActivity (MAC validation) → HomeActivity (category shelves) → (ChannelsActivity | VodCategoriesActivity | SeriesCategoriesActivity) → PlayerActivity (ExoPlayer). Session persists via SessionManager. UI driven by Retrofit repos. Coroutine-based async.

## Frequency & Cadence

Launch on-demand (user). Activation once per device. Category fetches on HomeActivity load (cached). Stream URLs fetched on player start (fresh). EPG (future) would be periodic fetch.

## Pressures Detected

Activation endpoint hard-coded (`api.miratv.club`). Credentials stored in SessionManager plaintext (should be EncryptedSharedPreferences). RecyclerView/Leanback mixed (not consistent). By-concepts endpoint sometimes returns 0 series (null-handling edge case). Adult PIN dialog not wired. Series categories endpoint returns 14 categories but drill-down unclear.

## Active Constraints

API 26+ (legacy support limits modern Android features). ExoPlayer 2.19.1 (older version, specific dependency). No local DB (SharedPreferences only). Single-repo pattern (all API calls through repos). No VPN SDK yet (planned Phase 10). No background sync.

## Short-Horizon Goals (Now → Soon)

Verify series categories drill-down working (by_concepts returning data). Wire parental PIN dialog. Test adult mode toggle. Verify favorites persistence. Build against all endpoints (series, VOD, live). Test on real TV hardware (Leanback).

## Long-Horizon Goals

Encrypt credentials (EncryptedSharedPreferences). Cloud favorites sync. Pluggable VPN provider. EPG overlay. Recording/DVR. Recommendation engine. Offline playback.

## Blind Spots

Unknown if all users can see live channels (depends on m3u_link, provider state). Unknown if series drill-down works reliably (inconsistent null fields). Unknown playback issues on various TV hardware (tested only on emulator?). Unknown if parental PIN works when enabled. Unknown user retention rate. Unknown which features matter most.

## Friction Points

Hard-coded endpoints (not configurable). Credentials not encrypted (security issue). No error recovery (failed API call doesn't retry). No offline fallback. RecyclerView jank on large category lists. Player doesn't show EPG. Category refresh is manual (no background refresh).

## Metrics Currently Used

App install count (from store). Crash reports (Firebase?). Usage (?) - unknown.

## Metrics Missing

Session success rate (% of activation attempts succeed). Stream playback success rate (% of playback attempts play vs. 404). Category load latency. Feature adoption (% using favorites, adult mode, PIN). Drop-off rate (activation → browse → stream).

## Suggested Stored Procedures (Do Not Exist Yet)

None required on app. (DB-side could track app telemetry, but not app responsibility.)

## Desired Context From Other Components

Xtream API: Which endpoints are stable? Activation: Device binding working? Series categories: Why are some drill-downs returning 0? EPG (future): What data format? VPN (future): Which providers supported?

## Confidence Level

High on architecture (three-layer pattern is solid, Retrofit repos work). High on core flow (splash → activation → home → player). Medium on edge cases (adult mode, PIN, edge cases). Low on real-world hardware (Leanback/TV testing). Low on user behavior (no analytics yet).

## Notes

App is a competent thin client but blind to backend issues. It succeeds or fails on stream URLs but has no way to diagnose why. This separation is intentional (UI doesn't need to know why DB rejected data) but means users get generic errors.
