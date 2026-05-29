# Master Control Ingest Manifest

This folder contains the machine-readable map of the current `C:\miratv_ingest` Master_Control / ingest flow.

## Files

```text
master_control_ingest_manifest.json
master_control_ingest_manifest.csv
```

## Purpose

The manifest records the current-system execution relationship without requiring the clean repo to import or execute the old system directly.

It now distinguishes three major current-system areas:

```text
provider_pull_spine
series_ingest / series_materialization
epg_refresh
```

## Current vs clean boundary

```text
Current system:
C:\miratv_ingest

Clean governed repo:
C:\miraTV_ingest_clean
```

The current system is source evidence.

The clean repo is the governed implementation lane.

Do not bulk-copy old files into the clean repo. Use this manifest to migrate or rewrite one capability at a time.

## Provider Pull Spine

The provider acquisition layer is represented by the `provider_pull_spine` section.

It includes:

```text
workers\spine\spine_master_import.bat
workers\spine\triggers\pull_live_cat_trigger.bat
workers\spine\triggers\pull_live_streams_trigger.bat
workers\spine\triggers\pull_vod_cat_trigger.bat
workers\spine\triggers\pull_vod_streams_trigger.bat
workers\spine\triggers\pull_series_trigger.bat
workers\spine\triggers\pull_series_trigger.ps1
workers\spine\triggers\pull_epg_trigger.bat

workers\spine\workers\pull_live_cat_worker.ps1
workers\spine\workers\pull_live_streams_worker.ps1
workers\spine\workers\pull_vod_cat_worker.ps1
workers\spine\workers\pull_vod_streams_worker.ps1
workers\spine\workers\pull_series_worker.ps1
workers\spine\workers\pull_epg_worker.ps1

workers\spine\call\import_live_categories.ps1
workers\spine\call\import_live_channels.ps1
workers\spine\call\import_vod_categories.ps1
workers\spine\call\import_vod_streams.ps1
workers\spine\call\import_series_json.ps1
workers\spine\call\import_epg.ps1
workers\spine\call\import_epg_chunked.ps1

workers\spine\state\live_streams.last
workers\spine\state\vod_streams.last
```

## Obsolete/reference collection note

The old Newman/Postman collections should not be treated as the active provider acquisition layer unless separately proven active.

For now:

```text
newman\series_pipeline.postman_collection.json = obsolete/reference
root *Collection*.postman_collection.json files = obsolete/reference
```

## Clean architecture direction

The old spine proves the system already had the right rough separation:

```text
pull provider payloads
import provider payloads
track last-state markers
```

The clean rebuild should replace this with:

```text
provider snapshot
delta comparison
targeted import/enqueue
materialization only where needed
structured signal/log/posterity
```

## Nomenclature rule

```text
One trailing number = order in Master_Control/master_runner sequence.
Two-number suffix = parent step plus sub-order inside that step/batch.
Query_Content2 is an exception because the 2 is part of the real base filename.
```

## Recommended clean repo location

```text
tools\config\master_control_ingest_manifest.json
tools\config\master_control_ingest_manifest.csv
tools\config\MASTER_CONTROL_INGEST_MANIFEST_README.md
```
