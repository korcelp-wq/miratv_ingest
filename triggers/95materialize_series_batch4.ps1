param(
    [int]$BatchSize = 10000,
    [int]$MaxLoops = 1,
    [int]$SleepSeconds = 4,
    [int]$StartId = 1,
    [int]$EndId = 2147483647,
    [string]$NameLike = ""
)

$QueryScript = "C:\miratv_ingest\dashboard\Query_Content4.ps1"
$WorkerScript = "C:\miratv_ingest\triggers\95materialize_series_batch_runner2.ps1"

Write-Host "=== SERIES BATCH MATERIALIZER START ==="
Write-Host "BatchSize=$BatchSize MaxLoops=$MaxLoops SleepSeconds=$SleepSeconds StartId=$StartId EndId=$EndId NameLike=$NameLike"

# Escape LIKE input
$escapedNameLike = $NameLike.Replace("'", "''")

for ($loop = 1; $loop -le $MaxLoops; $loop++) {

    Write-Host ""
    Write-Host "--- Loop $loop ---"

    # Optional name filter
    $nameFilter = ""
    if (-not [string]::IsNullOrWhiteSpace($NameLike)) {
        $nameFilter = "AND tmdb_search_name LIKE '%$escapedNameLike%'"
    }

    # Main query
    $sql = @"
SELECT id, tmdb_search_name
FROM series
WHERE id >= $StartId
  AND id <= $EndId
  AND (cover_url IS NULL OR cover_url = '')
ORDER BY id
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
    $lastId = $StartId

    foreach ($row in $rows) {

        $id = [int]$row.id
        $name = $row.tmdb_search_name
        $lastId = $id

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host "Skipping id=$id (no tmdb_search_name)"
            continue
        }

        Write-Host "Processing id=$id tmdb='$name'"

        try {
            & $WorkerScript -SeriesId $id
            $processed++
        }
        catch {
            Write-Host "FAILED id=$id : $_"
        }
    }

    # Move forward
    $StartId = $lastId + 1

    Write-Host "Loop $loop processed $processed row(s). Next StartId=$StartId. Sleeping $SleepSeconds second(s)..."

    Start-Sleep -Seconds $SleepSeconds
}

Write-Host ""
Write-Host "=== SERIES BATCH MATERIALIZER COMPLETE ==="