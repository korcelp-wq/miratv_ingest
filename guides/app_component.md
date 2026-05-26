# App Component Guide (Android Client)

**Component:** Android Client (app/)
**Domain:** IPTV Application
**Topic:** Mobile Client, UI, Playback
**Unit Type:** Application
**Created:** 2026-02-02

---

## Overview
The Android client is a Kotlin-based IPTV application supporting Xtream API (m3u playlists, live TV, VOD, series), targeting API 26+ and Leanback-compatible for Smart TVs. It uses ExoPlayer 2.19.1 for media playback and is built with Gradle 8.4.1, Kotlin 1.9.24, and Android SDK 34.

## Directory & Key Files
- **app/src/main/java/com/miratv/app/** – Main source code
  - `xtream/` – Retrofit API, repositories
  - `models/` – Domain models
  - `mapping/` – ModelMapper (raw → domain)
  - `ui/` – Activities (Activation, Home, Channels, Player, Series, VOD)
  - `util/` – SessionManager, PinManager, MacAddressProvider, AdultModeManager
  - `data/` – Local repositories (Favorites, VPN)
  - `AppState.kt` – Transient app state
- **app/build.gradle.kts** – Module build config
- **app/proguard-rules.pro** – ProGuard rules

## Key Workflows
- **Activation:** MAC/username validation → token storage → HomeActivity
- **Navigation:** Splash → Activation → Home → Channels/VOD/Series → Player
- **Playback:** ExoPlayer HLS/M3U8 via PlayerActivity
- **Session:** SessionManager persists ephemeral credentials
- **Parental Controls:** PinManager, AdultModeManager
- **Favorites:** FavoritesRepository (local, upgradeable)

## Integration Points
- **Xtream API:** Retrofit, ModelMapper, Repository pattern
- **Activation Endpoint:** MAC-based device binding
- **ExoPlayer:** HLS/M3U8 playback
- **Leanback:** TV UX

## CVI/Registry Notes
- All app logic is modular, repository-driven, and CVI-explicit for registry onboarding.
- See MIGRATION_PLAN.md for future upgrades (Room, EncryptedSharedPreferences, VPN, EPG overlay).

---

## Actionable Onboarding
- Build: `./gradlew assembleDebug`
- Install: `./gradlew :app:installDebug`
- Main entry: ActivationActivity
- Registry: All app modules are CVI-ready for PCDE_memory onboarding.
