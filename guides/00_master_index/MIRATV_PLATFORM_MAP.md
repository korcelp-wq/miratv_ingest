# MiraTV Platform Map

## Domains
- Auth (Login/Activation, PIN, Adult Mode)
- App (Favorites, UI, Scaling, Boot)
- Networking (VPN, Speed Test)
- Utility (Clear Cache, Recording)
- UI (EPG Overlay, Channel Seek)
- Content (Series Ingestion, Provider Normalization, Content Ingest)
- Monitoring (Telemetry)
- AI (Pipeline, CVI)
- Database (Registry, Backup)
- Governance (IGM)
- Operations (Disaster Recovery)
- Platform (Strategy, Vision)

## Feature Relationships
- Login/Activation → SessionManager → Retrofit → Secure Storage
- Favorites Sync → SharedPreferences → Room/Datastore → Cloud Sync
- Parental Lock → PinManager → UI Dialog
- Adult Mode → AdultModeManager → UI Toggle
- VPN → VpnServiceImpl → WireGuard/OpenVPN
- Series Ingestion → Grinder → DB → Normalization
- Telemetry → Spool → Monitoring Modules
- API Contract → Retrofit → Canonical Endpoints

## Guide References
- See MIRATV_GUIDE_INDEX.md for guide mapping.
