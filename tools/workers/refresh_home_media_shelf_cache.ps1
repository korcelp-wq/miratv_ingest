param(
    [string]$Environment = "dev",
    [int]$MacUserId = 6,
    [string]$AccountProvider = "fhkadvnp",
    [string]$VodSourceProvider = "fhkadvnp",
    [string]$SeriesSourceProvider = "eldervpn",
    [int]$LimitPerShelf = 14,
    [string]$KillSwitchName = "ENABLE_HOME_MEDIA_SHELF_CACHE_REFRESH"
)

$ErrorActionPreference = "Stop"

$WorkerName = "refresh_home_media_shelf_cache"
$Component = "home_media_shelf_cache"
$SignalName = "home_media_shelf_cache_refresh_completed"
$P0Item = "P0.5"

$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ"))-$([guid]::NewGuid().ToString("N"))"
$Stage = "init"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$LoggingModule = Join-Path $RepoRoot "tools\common\Logging.psm1"
$DbModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"

if (-not (Test-Path -LiteralPath $LoggingModule)) {
    throw "Missing logging module: $LoggingModule"
}

if (-not (Test-Path -LiteralPath $DbModule)) {
    throw "Missing DB module: $DbModule"
}

Import-Module $LoggingModule -Force
Import-Module $DbModule -Force

function ConvertTo-CompactJson {
    param([object]$Value)

    if ($null -eq $Value) {
        return "{}"
    }

    return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertTo-SqlString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    $s = [string]$Value
    $s = $s.Replace("'", "''")
    return "'$s'"
}

function New-ReportPaths {
    param(
        [string]$RepoRoot,
        [string]$Component
    )

    $OutputRoot = Join-Path $RepoRoot "runtime\reports\$Component"

    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
    }

    $Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

    [pscustomobject]@{
        OutputRoot = $OutputRoot
        ReportCsv = Join-Path $OutputRoot "$($Component)_report_$Stamp.csv"
        SummaryJson = Join-Path $OutputRoot "$($Component)_summary_$Stamp.json"
    }
}

function Write-WorkerEvent {
    param(
        [string]$EventType,
        [string]$Status,
        [hashtable]$Data
    )

    Write-JobLog `
        -RunId $RunId `
        -JobName $WorkerName `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -EventType $EventType `
        -Status $Status `
        -Data $Data | Out-Null
}

function Emit-WorkerSignal {
    param(
        [string]$SignalValue,
        [string]$Status,
        [hashtable]$Data
    )

    Emit-Signal `
        -RunId $RunId `
        -JobName $WorkerName `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName $SignalName `
        -P0Item $P0Item `
        -SignalValue $SignalValue `
        -Status $Status `
        -AllowedValues "pass|warning|fail|disabled" `
        -SourceTableOrEndpoint "tools/workers/refresh_home_media_shelf_cache.ps1" `
        -Data $Data | Out-Null
}

try {
    $Stage = "paths"
    $Paths = New-ReportPaths -RepoRoot $RepoRoot -Component $Component

    $Stage = "kill_switch"
    $KillEnabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $KillEnabled) {
        $Data = @{
            kill_switch_name = $KillSwitchName
            mac_user_id = $MacUserId
            account_provider = $AccountProvider
            vod_source_provider = $VodSourceProvider
            series_source_provider = $SeriesSourceProvider
            limit_per_shelf = $LimitPerShelf
        }

        Write-WorkerEvent -EventType "worker_blocked" -Status "blocked" -Data $Data
        Emit-WorkerSignal -SignalValue "disabled" -Status "disabled" -Data $Data

        $Summary = [pscustomobject]@{
            run_id = $RunId
            worker_name = $WorkerName
            component = $Component
            environment = $Environment
            status = "disabled"
            disposition = "kill_switch_disabled"
            kill_switch_name = $KillSwitchName
            mac_user_id = $MacUserId
            account_provider = $AccountProvider
            vod_source_provider = $VodSourceProvider
            series_source_provider = $SeriesSourceProvider
            limit_per_shelf = $LimitPerShelf
            report_csv = $null
            summary_json = $Paths.SummaryJson
        }

        $Summary | ConvertTo-Json -Depth 12 | Set-Content -Path $Paths.SummaryJson -Encoding UTF8

        Write-Output "BLOCKED: $WorkerName disabled by kill switch. run_id=$RunId"
        exit 0
    }

    $Stage = "worker_started"

    Write-WorkerEvent -EventType "worker_started" -Status "started" -Data @{
        event_message = "$WorkerName started."
        mac_user_id = $MacUserId
        account_provider = $AccountProvider
        vod_source_provider = $VodSourceProvider
        series_source_provider = $SeriesSourceProvider
        limit_per_shelf = $LimitPerShelf
    }

    $Stage = "home_media_shelf_cache_heartbeat"

    Emit-Heartbeat `
        -RunId $RunId `
        -JobName $WorkerName `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -HeartbeatStatus "ok" `
        -HeartbeatIntervalSeconds 300 `
        -StaleAfterSeconds 900 `
        -Data @{
            signal_name = "worker_heartbeat_status"
            p0_item = "P0.2"
            kill_switch_name = $KillSwitchName
            mac_user_id = $MacUserId
            account_provider = $AccountProvider
        } | Out-Null

    $Stage = "refresh_cache"

    $Sql = @"
CALL xpdgxfsp_content.sp_refresh_home_media_shelf_cache(
  $MacUserId,
  $(ConvertTo-SqlString $AccountProvider),
  $(ConvertTo-SqlString $VodSourceProvider),
  $(ConvertTo-SqlString $SeriesSourceProvider),
  $LimitPerShelf,
  $(ConvertTo-SqlString $RunId)
);
"@

    $RefreshResult = Invoke-DogOpenProc -DatabaseKey "content" -Sql $Sql -TimeoutSec 300
    $RefreshRows = @($RefreshResult.rows)

    $Stage = "validate_cache"

    $ValidateSql = @"
SELECT
  shelf_id,
  media_type,
  source_provider,
  COUNT(*) AS active_rows,
  MIN(rank_order) AS min_rank,
  MAX(rank_order) AS max_rank,
  MAX(updated_at) AS last_updated
FROM xpdgxfsp_content.home_media_shelf_cache
WHERE mac_user_id = $MacUserId
  AND account_provider = $(ConvertTo-SqlString $AccountProvider)
  AND cache_state = 'active'
GROUP BY shelf_id, media_type, source_provider
ORDER BY shelf_id;
"@

    $ValidateResult = Invoke-DogOpenProc -DatabaseKey "content" -Sql $ValidateSql -TimeoutSec 300
    $Rows = @($ValidateResult.rows)

    $Stage = "write_report"

    $Rows |
        Select-Object shelf_id, media_type, source_provider, active_rows, min_rank, max_rank, last_updated |
        Export-Csv -Path $Paths.ReportCsv -NoTypeInformation -Encoding UTF8

    $Movies = @($Rows | Where-Object { $_.shelf_id -eq "movies" })
    $Series = @($Rows | Where-Object { $_.shelf_id -eq "series" })
    $IntlMovies = @($Rows | Where-Object { $_.shelf_id -eq "intl_movies" })
    $IntlSeries = @($Rows | Where-Object { $_.shelf_id -eq "intl_series" })

    $MoviesCount = if ($Movies.Count -gt 0) { [int]$Movies[0].active_rows } else { 0 }
    $SeriesCount = if ($Series.Count -gt 0) { [int]$Series[0].active_rows } else { 0 }
    $IntlMoviesCount = if ($IntlMovies.Count -gt 0) { [int]$IntlMovies[0].active_rows } else { 0 }
    $IntlSeriesCount = if ($IntlSeries.Count -gt 0) { [int]$IntlSeries[0].active_rows } else { 0 }

    $Status = "pass"
    $SignalValue = "pass"
    $Disposition = "refresh_completed"

    if ($MoviesCount -lt 1 -or $SeriesCount -lt 1) {
        $Status = "warning"
        $SignalValue = "warning"
        $Disposition = "refresh_completed_with_missing_required_shelf"
    }

    $Summary = [pscustomobject]@{
        run_id = $RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        status = $Status
        signal_value = $SignalValue
        disposition = $Disposition
        mac_user_id = $MacUserId
        account_provider = $AccountProvider
        vod_source_provider = $VodSourceProvider
        series_source_provider = $SeriesSourceProvider
        limit_per_shelf = $LimitPerShelf
        refresh_rows = $RefreshRows.Count
        validation_rows = $Rows.Count
        movies_count = $MoviesCount
        series_count = $SeriesCount
        intl_movies_count = $IntlMoviesCount
        intl_series_count = $IntlSeriesCount
        report_csv = $Paths.ReportCsv
        summary_json = $Paths.SummaryJson
        cache_run_id = $RunId
    }

    $Summary | ConvertTo-Json -Depth 12 | Set-Content -Path $Paths.SummaryJson -Encoding UTF8

    $Stage = "emit_success"

    Write-WorkerEvent -EventType "worker_completed" -Status $Status -Data @{
        disposition = $Disposition
        report_csv = $Paths.ReportCsv
        summary_json = $Paths.SummaryJson
        movies_count = $MoviesCount
        series_count = $SeriesCount
        intl_movies_count = $IntlMoviesCount
        intl_series_count = $IntlSeriesCount
        cache_run_id = $RunId
    }

    Emit-WorkerSignal -SignalValue $SignalValue -Status $Status -Data @{
        disposition = $Disposition
        report_csv = $Paths.ReportCsv
        summary_json = $Paths.SummaryJson
        movies_count = $MoviesCount
        series_count = $SeriesCount
        intl_movies_count = $IntlMoviesCount
        intl_series_count = $IntlSeriesCount
        cache_run_id = $RunId
        kill_switch_name = $KillSwitchName
    }

    Write-Output "RESULT: $Status worker=$WorkerName run_id=$RunId movies=$MoviesCount series=$SeriesCount intl_movies=$IntlMoviesCount intl_series=$IntlSeriesCount report_csv=$($Paths.ReportCsv) summary_json=$($Paths.SummaryJson)"
    exit 0
}
catch {
    $ErrorMessage = "stage=$Stage; error=$($_.Exception.Message)"

    try {
        Write-WorkerEvent -EventType "worker_failed" -Status "failed" -Data @{
            error = $ErrorMessage
            mac_user_id = $MacUserId
            account_provider = $AccountProvider
            vod_source_provider = $VodSourceProvider
            series_source_provider = $SeriesSourceProvider
        }

        Emit-WorkerSignal -SignalValue "fail" -Status "fail" -Data @{
            error = $ErrorMessage
            kill_switch_name = $KillSwitchName
        }
    }
    catch {
        Write-Warning "Failed to emit failure logging/signal: $($_.Exception.Message)"
    }

    Write-Error "FAILED: $WorkerName failed. run_id=$RunId $ErrorMessage"
    exit 1
}


