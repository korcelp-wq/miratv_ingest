param(
    [int]$BatchSize = 15000,
    [int]$MaxLoops = 1,
    [int]$SleepSeconds = 4,
    [int]$StartId = 1,
    [int]$EndId = 2147483647,
    [string]$NameLike = "",
    [switch]$PosterOnly
)

$QueryScript = "C:\miratv_ingest\dashboard\Query_Content2.ps1"
$WorkerScript = "C:\miratv_ingest\triggers\95materialize_vod_batch_runner2.ps1"

Write-Host "=== VOD BATCH MATERIALIZER START ==="
Write-Host "BatchSize=$BatchSize MaxLoops=$MaxLoops SleepSeconds=$SleepSeconds StartId=$StartId EndId=$EndId NameLike=$NameLike PosterOnly=$PosterOnly"

$escapedNameLike = $NameLike.Replace("'", "''")

for ($loop = 1; $loop -le $MaxLoops; $loop++) {

    Write-Host ""
    Write-Host "--- Loop $loop ---"

    $nameFilter = ""
    if (-not [string]::IsNullOrWhiteSpace($NameLike)) {
        $nameFilter = "AND title LIKE '%$escapedNameLike%'"
    }

    if ($PosterOnly) {
        $missingFilter = @"
AND (
      poster_url IS NULL OR TRIM(poster_url) = ''
      OR cover_url IS NULL OR TRIM(cover_url) = ''
      OR provider_poster_url IS NULL OR TRIM(provider_poster_url) = ''
    )
"@
    }
    else {
        $missingFilter = @"
AND (
      poster_url IS NULL OR TRIM(poster_url) = ''
      OR cover_url IS NULL OR TRIM(cover_url) = ''
      OR provider_poster_url IS NULL OR TRIM(provider_poster_url) = ''
      OR plot IS NULL OR TRIM(plot) = ''
      OR rating IS NULL
      OR release_year IS NULL
      OR duration IS NULL
    )
"@
    }

    $sql = @"
SELECT vod_id, tmdb_search_name
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
        $lastId = $id

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host "Skipping vod_id=$id (no title)"
            $skipped++
            continue
        }

        Write-Host "Processing vod_id=$id title='$name'"

        try {
            & $WorkerScript -VodId $id
            if ($LASTEXITCODE -eq 0) {
                $processed++
            }
            else {
                Write-Host "FAILED vod_id=$id : Worker exit code $LASTEXITCODE"
                $failed++
            }
        }
        catch {
            Write-Host "FAILED vod_id=$id : $_"
            $failed++
        }
    }

    $StartId = $lastId + 1

    Write-Host "Loop $loop summary: processed=$processed skipped=$skipped failed=$failed nextStartId=$StartId"

    if ($processed -eq 0 -and $failed -eq 0) {
        Write-Host "No rows were actually processed in this loop. Exiting to avoid spinning."
        break
    }

    if ($loop -lt $MaxLoops) {
        Write-Host "Sleeping $SleepSeconds second(s)..."
        Start-Sleep -Seconds $SleepSeconds
    }
}

Write-Host ""
Write-Host "=== VOD BATCH MATERIALIZER COMPLETE ==="