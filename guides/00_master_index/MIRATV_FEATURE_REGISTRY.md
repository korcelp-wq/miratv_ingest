# MiraTV Feature Registry

| Feature Name | Status | Domain | Source Guide(s) | Evidence Summary | Dependencies | Notes |
|-------------|--------|--------|-----------------|------------------|-------------|------|
| Login/Activation | Implemented | Auth | MiraTV_Activation_Login_Flow_Authoritative.md, MIGRATION_PLAN.md | MAC + Username/Password, auto-login | SessionManager, Retrofit | Secure storage planned |
| Favorites Sync | Partial | App | MIGRATION_PLAN.md, README.md | Local persistence, Room/Datastore planned | SharedPreferences | Cloud sync future |
| Parental & Channel Lock | Partial | App | MIGRATION_PLAN.md, README.md | PIN-gated UI, dialog for channel selection | PinManager | Needs full UI wiring |
| Adult Channel Toggle | Implemented | App | MIGRATION_PLAN.md, README.md | 7 HOME presses to toggle visibility | AdultModeManager | Fully functional |
| Built-in VPN | Partial | Networking | MIGRATION_PLAN.md, README.md | Foreground-only, pluggable provider planned | VpnServiceImpl | WireGuard/OpenVPN integration |
| Speed Test | Partial | Utility | MIGRATION_PLAN.md, README.md | OkHttp ping + throughput test | OkHttp | Needs UI integration |
| Clear Cache | Partial | Utility | MIGRATION_PLAN.md, README.md | Purge image & EPG caches | Coil, app cache | Needs full implementation |
| Smart TV Scaling | Implemented | UI | MIGRATION_PLAN.md, README.md | DP-based sizing, Leanback compatibility | Android TV | Tested, working |
| Boot-on-Launch | Implemented | App | MIGRATION_PLAN.md, README.md | Optional via feature flag | BootReceiver | Feature flag controlled |
| Program Recording | Future | Utility | MIGRATION_PLAN.md, README.md | Placeholder module, DVR planned | Storage permissions | Needs full module |
| EPG Overlay/List | Partial | UI | MIGRATION_PLAN.md, README.md | Scaffolded, full overlay planned | EPG data | Overlay module needed |
| Room/Datastore for Favorites | Planned | App | MIGRATION_PLAN.md | Upgrade from SharedPreferences | Room/Datastore | Cloud sync hook |
| Pluggable VPN Provider | Planned | Networking | MIGRATION_PLAN.md | WireGuard/OpenVPN integration | VpnServiceImpl | Foreground-only rule |
| Full EPG Overlay & DVR Module | Planned | UI/Utility | MIGRATION_PLAN.md | Recording, TS/HLS write, storage permissions | EPG, Storage | Needs design |
| Security Hardening | Planned | Security | MIGRATION_PLAN.md | EncryptedSharedPreferences, remote config | Android Security | Not started |
| Channel Change Quick Seek | Partial | UI | MIGRATION_PLAN.md | Left/Right navigation in PlayerActivity | PlayerActivity | Needs implementation |
| PIN UI for Parental/Channel Lock | Partial | UI | MIGRATION_PLAN.md | Full implementation in ChannelsActivity | PinManager | UI wiring needed |
| Cloud Sync for Favorites | Future | App | MIGRATION_PLAN.md | After Room/Datastore upgrade | Room/Datastore | Not started |
| Series Ingestion Pipeline | Implemented | Content | MiraTV Series Ingest & Extraction.txt, series_grinder_pipeline_component.md | Grinder, normalization, materialization | Grinder, DB | Fully functional |
| Telemetry System | Implemented | Monitoring | TELEMETRY_SYSTEM_GUIDE.md | Telemetry, monitoring, spool | Telemetry modules | Working |
| AI Pipeline | Partial | AI | AI System Reflection & Architecture.txt, miratv_ai_pipeline_summary.md | AI pipeline summary, integration | CVI, AI modules | Needs expansion |
| Database Registry | Partial | Database | db_component_catalog.md | Database component catalog | DB modules | Needs backup module |
| Content Ingest | Implemented | Content | MiraTV Content Ingest — SCP Push Workflow (AUTHORITATIVE ADDENDUM).txt | SCP-based content ingest workflow | SCP, DB | Automated |
| Provider Normalization | Partial | Content | MiraTV Provider Normalization & Con.txt | Provider normalization notes | Provider modules | Needs completion |
| Disaster Recovery | Future | Operations | MiraTV_RESTORE_PLAN.md | Restore plan for MiraTV | Backup, DB | Not started |
| Governance/IGM | Partial | Governance | 2026-01-29__governance_igm__context_summary.md | Governance IGM context summary | Governance modules | Needs full implementation |
| API Contract | Implemented | API | MiraTV — Canonical API Contract.txt | Canonical API contract | API modules | Stable |
| Platform Strategy | Strategy | Platform | Strategic Infrastructure Alignment Platform.txt, Founder Master Strategy Document.txt | Platform vision, scaling, defense | N/A | Strategic planning |
