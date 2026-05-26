# MiraTV Guide Metadata Standard

## Metadata Schema (YAML Front Matter)

---
title:
domain:
component:
status:
depends_on:
feeds_into:
related_systems:
priority:
owner:
source_index:
---

## Allowed Values

- **status:**
  - implemented
  - partial
  - planned
  - future
  - strategy
  - unknown

- **domain:**
  - architecture
  - core_features
  - player_and_epg
  - content_ingest_pipeline
  - ai_and_pcde
  - operations
  - product_strategy

## Example

---
title: Series Ingest Pipeline
component: series_grinder_pipeline
status: implemented
domain: content_ingest_pipeline
depends_on: Xtream API Gateway
feeds_into: EPG System, Player System
related_systems: AI / PCDE, Telemetry System
priority: P1
owner: Content Ops Lead
source_index: MIRATV_GUIDE_INDEX.md
---

## Notes
- Place the YAML block at the very top of each guide file.
- Infer fields from filename, folder, and documentation index.
- Do not rewrite technical content.
- Use only allowed values for status and domain.
