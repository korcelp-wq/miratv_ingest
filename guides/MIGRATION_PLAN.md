# Migration Plan: CatchOnTV → MiraTv

## 1) Package & Manifest
- Package: com.miratv.app
- Launcher: ui.LoginActivity (LEANBACK compatible)
- Permissions: INTERNET, ACCESS_NETWORK_STATE, WAKE_LOCK, RECEIVE_BOOT_COMPLETED, FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK
- BootReceiver enables optional boot-on-launch

## 2) Login & Activation
- Recreate CatchOnTV’s flow: MAC or Username/Password → activate → auto-login thereafter
- Store ephemeral token; avoid persistent secrets
- Retrofit interface `api/XtreamApi.kt` mirrors player_api.php patterns

## 3) Navigation & UI
- `ui.LoginActivity` → `ui.HomeActivity` → `ui.PlayerActivity`
- Home lists categories (Live/VOD/Series/Favorites/Settings)
- Player uses ExoPlayer; left/right to change channels (TODO)

## 4) Features
- Favorites sync: persist locally (Room/Datastore) with future cloud hook
- Parental & Channel lock: PIN-gate specific groups/channels
- Hidden adult toggle: count 7 HOME presses to toggle adult visibility
- Built-in VPN: stubbed `service.VpnServiceImpl` for later provider integration
- Speed test: add OkHttp ping + throughput test (TODO)
- Clear cache: purge image & EPG caches (TODO)
- Smart TV scaling: ensure DP-based sizing; test common TV DPIs
- Boot-on-launch: controlled by feature flag
- Program recording: placeholder (DVR requires TS/HLS write + storage perms)

## 5) Endpoints
- Replace all with your domains:
  - https://api.miratv.club/player_api.php
  - https://panel.miratv.club/
- Implement resolver for alternate panels if needed.

## 6) Security
- Remove any vendor checks/smali traces
- Use encrypted storage for creds (EncryptedSharedPreferences) (TODO)
- Avoid exposing base URLs in clear (enable remote-config later)

## 7) Files to Port from CatchOnTV (conceptual mapping)
- Layout patterns (category grid, player overlay) → res/layout in MiraTv
- String keys/messages → res/values/strings.xml
- Player options (aspect ratio, buffer) → PlayerActivity
- EPG overlay → future module

## 8) Next Steps
- Wire real Xtream responses → models
- Implement channel list + quick seek (left/right)
- Add PIN UI for parental/channel lock
- Implement speed test & clear-cache screens
- Integrate chosen VPN SDK (WireGuard/OpenVPN) respecting foreground-only rule
- Add recording module with proper storage permission flow
