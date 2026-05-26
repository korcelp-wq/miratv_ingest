# MiraTv (Clean Scaffold)
Date: 2025-11-30T18:58:01.472945Z

This is a clean Android project scaffolding for MiraTv with the agreed features:
- Login: MAC + Username/Password with auto-login after activation
- Favorites sync, Parental lock, Channel lock
- Hidden adult channel toggle via 7 HOME presses
- Built-in VPN (foreground-only) + option to plug in your own VPN provider
- Speed test, Clear-cache tool
- Ephemeral device binding
- Smart TV auto-scaling support
- Boot-on-launch (optional)
- Program recording (placeholder module)

Open with Android Studio Giraffe+.


## Imported from CatchOnTV (Option C)
- strings_catchon.xml imported: True
- layouts imported (namespaced with 'catchon_'): none


## Added Features (Batch)
- EPG overlay/list scaffold
- Favorites repository (SharedPreferences)
- PIN dialog for parental/channel lock
- Channel change with Left/Right
- Speed test implementation (sample 1MB)
- Clear-cache implementation (Coil + app cache)
- Recording service placeholder (foreground)
