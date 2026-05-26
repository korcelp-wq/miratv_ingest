param(
    [int]$BatchSize = 3000,
    [int]$MaxLoops = 500,
    [int]$SleepSeconds = 4,
    [int]$StartId = 0,
    [int]$EndId = 2147483647,
    [string]$NameLike = "",
    [switch]$PosterOnly,
    [switch]$StopOnFailure
)

$QueryScript = "C:\miratv_ingest\dashboard\Query_Content2.ps1"
$WorkerScript = "C:\miratv_ingest\triggers\95materialize_vod_batch_runner.ps1"

Write-Host "=== VOD BATCH MATERIALIZER START ==="
Write-Host "BatchSize=$BatchSize MaxLoops=$MaxLoops SleepSeconds=$SleepSeconds StartId=$StartId EndId=$EndId NameLike=$NameLike PosterOnly=$PosterOnly StopOnFailure=$StopOnFailure"

if (-not (Test-Path $QueryScript)) {
    throw "Query script not found: $QueryScript"
}

if (-not (Test-Path $WorkerScript)) {
    throw "Worker script not found: $WorkerScript"
}

$escapedNameLike = $NameLike.Replace("'", "''")

$totalProcessed = 0
$totalSkipped = 0
$totalFailed = 0

for ($loop = 1; $loop -le $MaxLoops; $loop++) {

    Write-Host ""
    Write-Host "--- Loop $loop ---"

    $nameFilter = ""
    if (-not [string]::IsNullOrWhiteSpace($NameLike)) {
        $nameFilter = "AND title LIKE '%$escapedNameLike%'"
    }

    # PosterOnly means:
    # Only process rows missing app-facing image fields.
    #
    # Important:
    # provider_poster_url is intentionally NOT included here.
    # That field may be empty for many rows and would cause almost everything to reprocess.
    if ($PosterOnly) {
        $missingFilter = @"
AND (
      poster_url IS NULL OR TRIM(poster_url) = ''
      OR cover_url IS NULL OR TRIM(cover_url) = ''
    )
"@
    }
    else {
        $missingFilter = @"
AND (
      poster_url IS NULL OR TRIM(poster_url) = ''
      OR cover_url IS NULL OR TRIM(cover_url) = ''
      OR plot IS NULL OR TRIM(plot) = ''
      OR rating IS NULL
      OR release_year IS NULL
      OR duration IS NULL
    )
"@
    }

    $sql = @"
SELECT
    vod_id,
    tmdb_search_name,
    title
FROM vod
WHERE vod_id >= $StartId
  AND vod_id <= $EndId
  $missingFilter
  $nameFilter
ORDER BY vod_id
LIMIT $BatchSize;
"@

    try {
        $rows = & $QueryScript -Sql $sql -Db content
    }
    catch {
        Write-Host "FAILED querying batch rows: $_"
        break
    }

    if (-not $rows) {
        Write-Host "No candidate rows returned. Exiting."
        break
    }

    $rows = @($rows)
    $count = $rows.Count

    Write-Host "Rows returned: $count"

    if ($count -eq 0) {
        Write-Host "No more candidate rows found. Exiting."
        break
    }

    $processed = 0
    $skipped = 0
    $failed = 0
    $lastId = $StartId

    foreach ($row in $rows) {

        $id = [int]$row.vod_id
        $name = $row.tmdb_search_name

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $row.title
        }

        $lastId = $id

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host "Skipping vod_id=$id because tmdb_search_name/title is empty"
            $skipped++
            continue
        }

        Write-Host "Processing vod_id=$id title='$name'"

        try {
            $global:LASTEXITCODE = 0

            & $WorkerScript -VodId $id

            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Host "SUCCESS vod_id=$id"
                $processed++
            }
            else {
                Write-Host "FAILED vod_id=$id : Worker exit code $exitCode"
                $failed++

                if ($StopOnFailure) {
                    Write-Host "StopOnFailure enabled. Exiting current loop."
                    break
                }
            }
        }
        catch {
            Write-Host "FAILED vod_id=$id : $_"
            $failed++

            if ($StopOnFailure) {
                Write-Host "StopOnFailure enabled. Exiting current loop."
                break
            }
        }
    }

    $totalProcessed += $processed
    $totalSkipped += $skipped
    $totalFailed += $failed

    $StartId = $lastId + 1

    Write-Host "Loop $loop summary: processed=$processed skipped=$skipped failed=$failed nextStartId=$StartId"
    Write-Host "Running totals: processed=$totalProcessed skipped=$totalSkipped failed=$totalFailed"

    if ($StopOnFailure -and $failed -gt 0) {
        Write-Host "Stopping because StopOnFailure was enabled and at least one item failed."
        break
    }

    if ($processed -eq 0 -and $failed -eq 0) {
        Write-Host "No rows were actually processed in this loop. Exiting to avoid spinning."
        break
    }

    if ($StartId -gt $EndId) {
        Write-Host "StartId exceeded EndId. Exiting."
        break
    }

    if ($loop -lt $MaxLoops) {
        Write-Host "Sleeping $SleepSeconds second(s)..."
        Start-Sleep -Seconds $SleepSeconds
    }
}

Write-Host ""
Write-Host "=== VOD BATCH MATERIALIZER COMPLETE ==="
Write-Host "Final totals: processed=$totalProcessed skipped=$totalSkipped failed=$totalFailed"