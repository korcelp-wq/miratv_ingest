<#
.SYNOPSIS
  Plan top-level Series delta from latest provider series snapshot JSON against local series table.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "eldervpn",
    [int]$MacUserId = 6,
    [int]$DbBatchSize = 500,
    [string]$SnapshotPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "plan_series_top_level_delta"
$Component = "series_top_level_delta_plan"
$KillSwitchName = "ENABLE_SERIES_TOP_LEVEL_DELTA_PLAN"
$DatabaseKey = "content"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\series_top_level_delta_plan"
$LogDir = Join-Path $RepoRoot "runtime\logs\series_top_level_delta_plan"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$CsvPath = Join-Path $ReportDir "series_top_level_delta_plan_$Stamp.csv"
$SummaryPath = Join-Path $ReportDir "series_top_level_delta_plan_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "$WorkerName-$($StartedAt.ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}

function Write-JobLog {
    param([string]$EventName, [string]$Status, [object]$Data = $null)

    $record = [ordered]@{
        event_ts = (Get-Date).ToUniversalTime().ToString("o")
        event_name = $EventName
        job_name = $WorkerName
        run_id = $RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        provider = $Provider
        status = $Status
        data = $Data
    }

    Add-Content -Path $LogPath -Value ($record | ConvertTo-Json -Depth 12 -Compress) -Encoding UTF8
}

function Emit-Signal {
    param([string]$SignalName, [object]$SignalValue, [object]$Payload = $null)

    Write-JobLog -EventName "signal_emitted" -Status "ok" -Data ([ordered]@{
        signal_name = $SignalName
        signal_value = $SignalValue
        payload = $Payload
    })
}

function Emit-Heartbeat {
    param([string]$Status = "ok")
    Write-JobLog -EventName "heartbeat" -Status $Status -Data ([ordered]@{})
}

function Test-KillSwitch {
    $raw = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    return ($raw.Trim().ToLowerInvariant() -notin @("0","false","no","off","disabled"))
}

function Invoke-ReadSql {
    param([string]$Sql)

    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    Import-Module $modulePath -Force
    return Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $Sql -TimeoutSec 180
}

function Escape-SqlString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("'", "''")
}

function Get-FirstString {
    param(
        [object]$Object,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value) {
                $text = [string]$value
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    return $text.Trim()
                }
            }
        }
    }

    return ""
}

function Get-FirstInt {
    param(
        [object]$Object,
        [string[]]$Names
    )

    $text = Get-FirstString -Object $Object -Names $Names
    $n = 0
    if ([int]::TryParse($text, [ref]$n)) {
        return $n
    }

    return 0
}

function Convert-ToCleanSeriesName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }

    $clean = $Name.Trim()

    # Remove common provider language prefix before pipe, e.g. "EN| Title", "ES| Title"
    $clean = [regex]::Replace($clean, '^\s*[A-Z]{2,4}\s*\|\s*', '', 'IgnoreCase')

    # Remove common bracket tags but avoid destroying the title itself.
    $clean = [regex]::Replace($clean, '\[(MULTI[- ]?SUB|4K|HD|FHD|UHD|SUB|DUB|BLACK/WHITE|BLACK WHITE)\]', '', 'IgnoreCase')

    # Normalize punctuation spacing, but keep readable words.
    $clean = $clean -replace '\s+', ' '
    $clean = $clean.Trim()

    return $clean
}

function Convert-ToSearchName {
    param([string]$Name)

    $clean = Convert-ToCleanSeriesName -Name $Name
    if ([string]::IsNullOrWhiteSpace($clean)) { return "" }

    $clean = $clean -replace '[^\p{L}\p{Nd}]+', ' '
    $clean = $clean -replace '\s+', ' '
    return $clean.Trim()
}

function Get-HashForProviderRow {
    param([object]$Item)

    $hashInput = [ordered]@{
        series_id = Get-FirstInt -Object $Item -Names @("series_id", "id")
        name = Get-FirstString -Object $Item -Names @("name", "title")
        category_id = Get-FirstString -Object $Item -Names @("category_id")
        cover = Get-FirstString -Object $Item -Names @("cover", "cover_url", "poster")
        plot = Get-FirstString -Object $Item -Names @("plot", "overview")
        genre = Get-FirstString -Object $Item -Names @("genre")
        releaseDate = Get-FirstString -Object $Item -Names @("releaseDate", "release_date")
        rating = Get-FirstString -Object $Item -Names @("rating")
        last_modified = Get-FirstString -Object $Item -Names @("last_modified")
    }

    $json = $hashInput | ConvertTo-Json -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-LatestSnapshotPath {
    $latestReport = Get-ChildItem (Join-Path $RepoRoot "runtime\reports\provider_series_streams_snapshot\provider_series_streams_snapshot_report_*.csv") |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latestReport) {
        throw "No provider_series_streams_snapshot report CSV found."
    }

    $row = Import-Csv $latestReport.FullName | Select-Object -First 1
    $path = [string]$row.snapshot_path

    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "Latest provider_series_streams_snapshot report has no snapshot_path."
    }

    return $path
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    if ($DbBatchSize -lt 1 -or $DbBatchSize -gt 5000) {
        throw "DbBatchSize must be between 1 and 5000."
    }

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        mac_user_id = $MacUserId
        db_batch_size = $DbBatchSize
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
    })

    Emit-Heartbeat -Status "loading_snapshot"

    if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
        $SnapshotPath = Get-LatestSnapshotPath
    }

    if (-not (Test-Path -LiteralPath $SnapshotPath)) {
        throw "SnapshotPath not found: $SnapshotPath"
    }

    $json = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    $items = @($json)

    $providerRows = foreach ($item in $items) {
        $providerSeriesId = Get-FirstInt -Object $item -Names @("series_id", "id")
        $providerName = Get-FirstString -Object $item -Names @("name", "title")
        $cleanName = Convert-ToCleanSeriesName -Name $providerName
        $searchName = Convert-ToSearchName -Name $providerName
        $categoryId = Get-FirstInt -Object $item -Names @("category_id")
        $cover = Get-FirstString -Object $item -Names @("cover", "cover_url", "poster")
        $backdrop = ""

        if ($item.PSObject.Properties.Name -contains "backdrop_path" -and $null -ne $item.backdrop_path) {
            $firstBackdrop = $null

            if ($item.backdrop_path -is [array]) {
                $firstBackdrop = $item.backdrop_path | Where-Object {
                    $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)
                } | Select-Object -First 1
            }
            else {
                $firstBackdrop = $item.backdrop_path
            }

            if ($null -ne $firstBackdrop -and -not [string]::IsNullOrWhiteSpace([string]$firstBackdrop)) {
                $backdrop = ([string]$firstBackdrop).Trim()
            }
        }

        [pscustomobject][ordered]@{
            provider = $Provider
            provider_series_id = $providerSeriesId
            provider_name = $providerName
            clean_search_name = $searchName
            display_clean_name = $cleanName
            provider_category_id = $categoryId
            provider_cover_url = $cover
            provider_backdrop_url = $backdrop
            provider_last_modified = Get-FirstInt -Object $item -Names @("last_modified")
            provider_row_hash = Get-HashForProviderRow -Item $item
        }
    }

    $providerRows = @($providerRows | Where-Object { $_.provider_series_id -gt 0 })

    $dbByProviderId = @{}
    $dbCountByProviderId = @{}
    $ids = @($providerRows.provider_series_id | Sort-Object -Unique)

    Emit-Heartbeat -Status "loading_db_rows"

    for ($i = 0; $i -lt $ids.Count; $i += $DbBatchSize) {
        $batchIds = @($ids[$i..([Math]::Min($i + $DbBatchSize - 1, $ids.Count - 1))])
        $idList = ($batchIds | ForEach-Object { [int]$_ }) -join ","
        $providerEscaped = Escape-SqlString -Value $Provider

        $sql = @"
SELECT
  id,
  provider_series_id,
  provider,
  name,
  clean_search_name,
  tmdb_search_name,
  category_id,
  cover_url,
  backdrop_url,
  provider_cover_url,
  provider_backdrop_url,
  poster_url,
  provider_poster_url,
  last_modified,
  ingest_hash
FROM series
WHERE provider = '$providerEscaped'
  AND provider_series_id IN ($idList);
"@

        $result = Invoke-ReadSql -Sql $sql
        foreach ($dbRow in @($result.rows)) {
            $dbKey = [string]$dbRow.provider_series_id

            if (-not $dbCountByProviderId.ContainsKey($dbKey)) {
                $dbCountByProviderId[$dbKey] = 0
            }

            $dbCountByProviderId[$dbKey] = [int]$dbCountByProviderId[$dbKey] + 1

            if (-not $dbByProviderId.ContainsKey($dbKey)) {
                $dbByProviderId[$dbKey] = $dbRow
            }
        }

        if (($i % ($DbBatchSize * 10)) -eq 0) {
            Emit-Heartbeat -Status "db_batch_$i"
        }
    }

    Emit-Heartbeat -Status "planning_delta"

    $planRows = foreach ($p in $providerRows) {
        $key = [string]$p.provider_series_id
        $matchCount = 0
        $matchRow = $null

        if ($dbCountByProviderId.ContainsKey($key)) {
            $matchCount = [int]$dbCountByProviderId[$key]
        }

        if ($dbByProviderId.ContainsKey($key)) {
            $matchRow = $dbByProviderId[$key]
        }

        $disposition = "already_current"
        $changeReasons = New-Object System.Collections.Generic.List[string]
        $localId = ""
        $localName = ""
        $localClean = ""
        $localCategoryId = ""
        $localCover = ""
        $localBackdrop = ""
        $localHash = ""

        if ($matchCount -eq 0) {
            $disposition = "planned_insert"
            $changeReasons.Add("provider_series_id_not_found")
        }
        elseif ($matchCount -gt 1) {
            $disposition = "needs_review_duplicate_provider_series_id"
            $changeReasons.Add("duplicate_provider_series_id")
        }
        else {
            $m = $matchRow
            $localId = [string]$m.id
            $localName = [string]$m.name
            $localClean = [string]$m.clean_search_name
            $localCategoryId = [string]$m.category_id
            $localCover = [string]$m.cover_url
            $localBackdrop = [string]$m.backdrop_url
            $localHash = [string]$m.ingest_hash

            if ($localName.Trim() -ne $p.provider_name.Trim()) {
                $changeReasons.Add("name_changed")
            }

            if ($localClean.Trim() -ne $p.clean_search_name.Trim()) {
                $changeReasons.Add("clean_search_name_changed")
            }

            if ($localCategoryId.Trim() -ne ([string]$p.provider_category_id)) {
                $changeReasons.Add("category_changed")
            }

            if ([string]::IsNullOrWhiteSpace($localCover) -and -not [string]::IsNullOrWhiteSpace($p.provider_cover_url)) {
                $changeReasons.Add("cover_missing_locally")
            }

            if ([string]::IsNullOrWhiteSpace($localBackdrop) -and -not [string]::IsNullOrWhiteSpace($p.provider_backdrop_url)) {
                $changeReasons.Add("backdrop_missing_locally")
            }

            if ($localHash.Trim() -ne $p.provider_row_hash.Trim()) {
                $changeReasons.Add("provider_row_hash_changed")
            }

            $actionableReasons = @(
                $changeReasons | Where-Object {
                    $_ -in @(
                        "category_changed",
                        "cover_missing_locally",
                        "backdrop_missing_locally"
                    )
                }
            )

            if ($actionableReasons.Count -gt 0) {
                $disposition = "planned_update"
            }
        }

        [pscustomobject][ordered]@{
            import_status = ""
            row_disposition = $disposition
            change_reasons = ($changeReasons -join ";")
            provider = $p.provider
            provider_series_id = $p.provider_series_id
            provider_name = $p.provider_name
            display_clean_name = $p.display_clean_name
            clean_search_name = $p.clean_search_name
            provider_category_id = $p.provider_category_id
            provider_cover_url = $p.provider_cover_url
            provider_backdrop_url = $p.provider_backdrop_url
            provider_last_modified = $p.provider_last_modified
            provider_row_hash = $p.provider_row_hash
            local_series_id = $localId
            local_name = $localName
            local_clean_search_name = $localClean
            local_category_id = $localCategoryId
            local_cover_url = $localCover
            local_backdrop_url = $localBackdrop
            local_ingest_hash = $localHash
        }
    }

    $planRows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        mac_user_id = $MacUserId
        snapshot_path = $SnapshotPath
        provider_rows = $providerRows.Count
        plan_rows = @($planRows).Count
        already_current = @($planRows | Where-Object { $_.row_disposition -eq "already_current" }).Count
        planned_insert = @($planRows | Where-Object { $_.row_disposition -eq "planned_insert" }).Count
        planned_update = @($planRows | Where-Object { $_.row_disposition -eq "planned_update" }).Count
        needs_review = @($planRows | Where-Object { $_.row_disposition -like "needs_review*" }).Count
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
        report_csv = $CsvPath
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "pass"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8

    Emit-Signal -SignalName "series_top_level_delta_plan_completed" -SignalValue "pass" -Payload $summary
    Write-JobLog -EventName "job_completed" -Status "pass" -Data $summary

    Write-Output "OK: Series top-level delta plan completed. rows=$($summary.plan_rows) inserts=$($summary.planned_insert) updates=$($summary.planned_update) review=$($summary.needs_review) summary=$SummaryPath"
}
catch {
    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        mac_user_id = $MacUserId
        last_error = $_.Exception.Message
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "series_top_level_delta_plan_completed" -SignalValue "failed" -Payload $summary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $summary
    throw
}





