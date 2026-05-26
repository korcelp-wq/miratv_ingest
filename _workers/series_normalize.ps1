$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest



$WORKER = "series_normalize"
$STAGE  = "normalize"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Emit-Ops -Event "WORKER_START" -Worker $WORKER -Stage $STAGE

try {
    $RAW_DIR = "C:\miratv_ingest\raw_store"
    $OUT_DIR = "C:\miratv_ingest\raw_store\normalized"

    if (-not (Test-Path $RAW_DIR)) {
        Emit-IGM  -CanonState "CANON_SKIPPED" -Worker $WORKER -Stage $STAGE -Fields @{ reason = "raw_dir_missing" }
        Emit-Lake -Signal "zero_input"        -Worker $WORKER -Stage $STAGE
        return
    }

    if (-not (Test-Path $OUT_DIR)) {
        New-Item -ItemType Directory -Force -Path $OUT_DIR | Out-Null
    }

    $rawFiles = Get-ChildItem $RAW_DIR -Filter "*.raw.json" -Recurse
    if (-not $rawFiles) {
        Emit-IGM  -CanonState "CANON_SKIPPED" -Worker $WORKER -Stage $STAGE -Fields @{ reason = "no_raw_files" }
        Emit-Lake -Signal "zero_input"        -Worker $WORKER -Stage $STAGE
        return
    }

    $processed = 0

    foreach ($file in $rawFiles) {
        try {
            $text = Get-Content $file.FullName -Raw -Encoding UTF8

            # Treat JSON as structured text, not a streaming contract
            $data = $text | ConvertFrom-Json

            $normalized = [ordered]@{
                source_file = $file.Name
                normalized_at = (Get-Date).ToString("o")
                payload = $data
            }

            $outFile = Join-Path $OUT_DIR $file.Name
            $normalized | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $outFile

            $processed++
        }
        catch {
            Emit-Ops -Event "NORMALIZE_ERROR" -Worker $WORKER -Stage $STAGE -Fields @{
                file    = $file.Name
                message = $_.Exception.Message
            }
        }
    }

    if ($processed -gt 0) {
        Emit-IGM  -CanonState "CANON_OK" -Worker $WORKER -Stage $STAGE
        Emit-Lake -Signal "units_emitted" -Worker $WORKER -Stage $STAGE -Fields @{ count = $processed }
    } else {
        Emit-IGM  -CanonState "CANON_INCOMPLETE" -Worker $WORKER -Stage $STAGE -Fields @{ reason = "no_successful_units" }
    }
}
catch {
    Emit-Ops -Event "FATAL_ERROR" -Worker $WORKER -Stage $STAGE -Fields @{ message = $_.Exception.Message }
    Emit-IGM -CanonState "CANON_INCOMPLETE" -Worker $WORKER -Stage $STAGE -Fields @{ error = $_.Exception.Message }
    throw
}
finally {
    $sw.Stop()
    Emit-Ops -Event "WORKER_END" -Worker $WORKER -Stage $STAGE -Fields @{ duration_ms = $sw.ElapsedMilliseconds }
}
