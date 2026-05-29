# Master Control Ingest Manifest

This folder contains the machine-readable map of the current `C:\miratv_ingest` Master_Control / master_runner2 ingest flow.

## Files

```text
master_control_ingest_manifest.json
master_control_ingest_manifest.csv
```

## Purpose

The manifest records the current-system execution relationship without requiring the clean repo to import or execute the old system directly.

It captures:

```text
current system root
clean system root
Master_Control/master_runner order
parent trigger/batch files
subfiles inside each batch/step
current relative paths
current absolute paths
roles
lanes
migration status
contract gaps
secret-risk classification
```

## Important distinction

```text
Current system:
C:\miratv_ingest

Clean governed repo:
C:\miraTV_ingest_clean
```

The current system is the operational source/reference.

The clean repo is the governed implementation lane.

Do not bulk-copy files from `C:\miratv_ingest` into the clean repo. Use this manifest to migrate or rewrite one capability at a time.

## Nomenclature rule

```text
One trailing number = order in Master_Control/master_runner sequence.
Two-number suffix = parent step plus sub-order inside that step/batch.
Query_Content2 is an exception because the 2 is part of the real base filename.
```

## Current lanes represented

```text
series_ingest
series_materialization
epg_refresh
```

## Recommended clean repo location

```text
tools\config\master_control_ingest_manifest.json
tools\config\master_control_ingest_manifest.csv
tools\config\MASTER_CONTROL_INGEST_MANIFEST_README.md
```

## How to use

Use the JSON file for automation and validation.

Use the CSV file for quick human review or spreadsheet-style filtering.

The manifest is not an execution script. It is a control map used to decide what should be reviewed, migrated, rewritten, or governed next.
