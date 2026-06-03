<#
.SYNOPSIS
  EPG Gate 3: Import/upsert database only, with spine logging.

.DESCRIPTION
  Retries the database import/upsert loop against the existing server-side EPG file:
    /home/xpdgxfsp/public_html/miratv.club/automated/epg.xml

  This worker does not download and does not upload.

  Use this when the XML file is already on the server and only the DB upsert/import
  needs to be retried or continued.

  Spine logging:
    - Writes DB-backed events through xpdgxfsp_content.sp_record_spine_worker_event
      when the DB logging objects are installed.
    - By default, spine logging failure is warning-only so the EPG import path is not blocked.
    - Use -RequireSpineDbLogging to make missing/broken logging a hard gate failure.

.NOTES
  Default behavior resets the importer offset once, then imports to completion.
  Use -NoReset when you intentionally want to continue from the current importer offset.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$ImportUrl = "https://miratv.club/_ingest/import_epg.php",
    [string]$IngestToken = "",
    [int]$ImportLimit = 19000,
    [int]$MaxImportRuns = 20,
    [int]$SleepSeconds = 1,
    [int]$ImportResetRetryCount = 10,
    [int]$ImportResetRetrySeconds = 6,
    [switch]$NoReset,
    [switch]$SkipDbFreshnessCheck,
    [switch]$SkipLiveCacheEnrichment,
    [int]$MacUserId = 6,
    [string]$RepoRoot = "",
    [string]$WorkerKey = "epg_db_import_upsert",
    [string]$StageKey = "media_refresh.epg.import",
    [switch]$FailIfMaxRunsReachedWithFullBatch,
    [switch]$DisableSpineDbLogging,
    [switch]$RequireSpineDbLogging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}

$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-db-import-$Stamp"
$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_db_import"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$ReportCsv = Join-Path $ReportDir "epg_db_import_$Stamp.csv"
$SummaryJson = Join-Path $ReportDir "epg_db_import_summary_$Stamp.json"

$ImportRows = New-Object System.Collections.Generic.List[object]

function Test-JsonProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JsonPropertyValue {
    param([object]$Object, [string]$Name, [object]$DefaultValue = $null)
    if (Test-JsonProperty -Object $Object -Name $Name) { return $Object.$Name }
    return $DefaultValue
}

function ConvertTo-CompactJson {
    param([object]$Value)

    if ($null -eq $Value) { return "" }
    return ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertTo-SqlString {
    param([object]$Value)

    if ($null -eq $Value) { return "NULL" }

    $textValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($textValue)) { return "NULL" }

    return "'" + ($textValue.Replace("'", "''")) + "'"
}

function Invoke-SpineEvent {
    param(
        [string]$EventType,
        [string]$Status,
        [string]$SignalKey,
        [string]$Disposition,
        [object]$Metrics = $null,
        [string]$ReportCsvPath = "",
        [string]$SummaryJsonPath = "",
        [string]$ErrorMessage = ""
    )

    if ($DisableSpineDbLogging) {
        return
    }

    $module = Join-Path $RepoRoot "tools\common\DbQuery.psm1"

    try {
        if (-not (Test-Path -LiteralPath $module)) {
            throw "DbQuery module not found: $module"
        }

        Import-Module $module -Force

        $metricsJson = ConvertTo-CompactJson -Value $Metrics

        $sql = @"
CALL xpdgxfsp_content.sp_record_spine_worker_event(
  $(ConvertTo-SqlString $RunId),
  $(ConvertTo-SqlString $WorkerKey),
  $(ConvertTo-SqlString $StageKey),
  $(ConvertTo-SqlString $Environment),
  $(ConvertTo-SqlString $Status),
  $(ConvertTo-SqlString $EventType),
  $(ConvertTo-SqlString $SignalKey),
  $(ConvertTo-SqlString $Disposition),
  $(ConvertTo-SqlString $metricsJson),
  $(ConvertTo-SqlString $ReportCsvPath),
  $(ConvertTo-SqlString $SummaryJsonPath),
  $(ConvertTo-SqlString $ErrorMessage)
);
"@

        Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120 | Out-Null
    }
    catch {
        $message = "spine logging failed: $($_.Exception.Message)"

        if ($RequireSpineDbLogging) {
            throw $message
        }

        Write-Warning $message
    }
}

function Get-SecretToken {
    param([string]$Provided)

    if (-not [string]::IsNullOrWhiteSpace($Provided)) { return $Provided.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:MIRATV_INGEST_TOKEN)) { return $env:MIRATV_INGEST_TOKEN.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($env:DOG_OPEN_PROC_TOKEN)) { return $env:DOG_OPEN_PROC_TOKEN.Trim() }

    throw "No ingest token provided. Set -IngestToken or env:MIRATV_INGEST_TOKEN."
}

function Invoke-ImportEndpoint {
    param(
        [string]$Url,
        [string]$Token,
        [hashtable]$Query,
        [int]$TimeoutSec = 300
    )

    $builder = [System.UriBuilder]$Url
    $pairs = New-Object System.Collections.Generic.List[string]
    $pairs.Add("token=$([System.Uri]::EscapeDataString($Token))") | Out-Null

    foreach ($key in $Query.Keys) {
        $pairs.Add("$key=$([System.Uri]::EscapeDataString([string]$Query[$key]))") | Out-Null
    }

    $builder.Query = ($pairs -join "&")
    $uri = $builder.Uri.AbsoluteUri

    $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec $TimeoutSec
    return ($response.Content | ConvertFrom-Json)
}

function Assert-ImportResponseOk {
    param([object]$Json, [string]$StepName, [switch]$RequireProcessed)

    if ($null -eq $Json) { throw "$StepName returned no JSON." }

    $errorValue = Get-JsonPropertyValue -Object $Json -Name "error" -DefaultValue ""
    if (-not [string]::IsNullOrWhiteSpace([string]$errorValue)) {
        $fileValue = Get-JsonPropertyValue -Object $Json -Name "file" -DefaultValue ""
        throw "$StepName returned error: $errorValue file=$fileValue"
    }

    if (-not (Test-JsonProperty -Object $Json -Name "success")) {
        $shape = ($Json.PSObject.Properties.Name -join ",")
        throw "$StepName response missing success property. Shape=$shape"
    }

    if ($Json.success -ne $true) { throw "$StepName returned success=false." }

    if ($RequireProcessed) {
        $processed = [int](Get-JsonPropertyValue -Object $Json -Name "processed_this_run" -DefaultValue 0)
        if ($processed -lt 1) { throw "$StepName processed_this_run < 1." }
    }
}

function Invoke-DbFreshnessCheck {
    param([string]$RepoRoot)

    $module = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    if (-not (Test-Path -LiteralPath $module)) {
        throw "DbQuery module not found: $module"
    }

    Import-Module $module -Force

    $sql = @"
SELECT
  COUNT(*) AS total_epg_rows,
  COUNT(DISTINCT epg_channel_id) AS distinct_epg_channels,
  MIN(start_time) AS min_start_time,
  MAX(start_time) AS max_start_time,
  MIN(end_time) AS min_end_time,
  MAX(end_time) AS max_end_time,
  UTC_TIMESTAMP() AS utc_now,
  SUM(CASE WHEN UTC_TIMESTAMP() >= start_time AND UTC_TIMESTAMP() < end_time THEN 1 ELSE 0 END) AS currently_active_programs,
  SUM(CASE WHEN start_time > UTC_TIMESTAMP() THEN 1 ELSE 0 END) AS future_programs
FROM xpdgxfsp_content.epg_programs;
"@

    $result = Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120
    return @($result.rows)[0]
}

function Invoke-LiveCacheEnrichment {
    param([string]$RepoRoot, [int]$MacUserId)

    $module = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    Import-Module $module -Force

    $sql = "CALL xpdgxfsp_content.sp_enrich_live_screen_cache_epg($MacUserId, 'live');"
    return Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 300
}

function Get-ImportAggregateMetrics {
    $processed = 0
    $inserted = 0
    $lastOffset = 0
    $lastProcessed = 0

    foreach ($row in $ImportRows) {
        $processed += [int]$row.processed_this_run
        $inserted += [int]$row.inserted_this_run
        $lastOffset = [int]$row.next_offset
        $lastProcessed = [int]$row.processed_this_run
    }

    return [pscustomobject]@{
        import_runs = $ImportRows.Count
        imported_rows = $processed
        inserted_rows = $inserted
        last_next_offset = $lastOffset
        last_processed_this_run = $lastProcessed
        import_limit = $ImportLimit
        max_import_runs = $MaxImportRuns
        reset_ran = (-not $NoReset)
        no_reset = [bool]$NoReset
    }
}

try {
    Invoke-SpineEvent -EventType "signal" -Status "running" -SignalKey "epg_db_import_started" -Disposition "db_import_started" -Metrics ([pscustomobject]@{
        import_url = $ImportUrl
        import_limit = $ImportLimit
        max_import_runs = $MaxImportRuns
        no_reset = [bool]$NoReset
        skip_db_freshness_check = [bool]$SkipDbFreshnessCheck
        skip_live_cache_enrichment = [bool]$SkipLiveCacheEnrichment
        mac_user_id = $MacUserId
    })

    $token = Get-SecretToken -Provided $IngestToken

    $resetJson = $null
    if (-not $NoReset) {
        Write-Host "[import_reset] Resetting import offset once with limit=1"

        $resetOk = $false
        $lastResetError = ""

        for ($resetAttempt = 1; $resetAttempt -le $ImportResetRetryCount; $resetAttempt++) {
            Write-Host "[import_reset] Attempt $resetAttempt / $ImportResetRetryCount"

            try {
                $resetJson = Invoke-ImportEndpoint -Url $ImportUrl -Token $token -Query @{ reset = 1; limit = 1 } -TimeoutSec 120
                $resetJson | Format-List
                Assert-ImportResponseOk -Json $resetJson -StepName "import_reset" -RequireProcessed
                $resetOk = $true

                Invoke-SpineEvent -EventType "heartbeat" -Status "running" -SignalKey "epg_db_import_reset_completed" -Disposition "reset_once_completed" -Metrics $resetJson

                break
            }
            catch {
                $lastResetError = $_.Exception.Message
                Write-Host "[import_reset] Not ready yet: $lastResetError" -ForegroundColor Yellow

                Invoke-SpineEvent -EventType "heartbeat" -Status "running" -SignalKey "epg_db_import_reset_retry" -Disposition "reset_retry" -Metrics ([pscustomobject]@{
                    attempt = $resetAttempt
                    max_attempts = $ImportResetRetryCount
                    error = $lastResetError
                })

                if ($resetAttempt -lt $ImportResetRetryCount) {
                    Start-Sleep -Seconds $ImportResetRetrySeconds
                }
            }
        }

        if (-not $resetOk) {
            throw "import_reset failed after $ImportResetRetryCount attempts. Last error: $lastResetError"
        }
    }
    else {
        Write-Host "[import_reset] Skipped because -NoReset was supplied."
        Invoke-SpineEvent -EventType "heartbeat" -Status "running" -SignalKey "epg_db_import_reset_skipped" -Disposition "no_reset_requested" -Metrics @{ no_reset = $true }
    }

    $completedNaturally = $false
    $maxRunsReachedWithFullBatch = $false

    for ($i = 1; $i -le $MaxImportRuns; $i++) {
        Write-Host "[import_loop] EPG import run $i / $MaxImportRuns"
        $json = Invoke-ImportEndpoint -Url $ImportUrl -Token $token -Query @{ limit = $ImportLimit } -TimeoutSec 300
        Assert-ImportResponseOk -Json $json -StepName "import_loop"

        $row = [pscustomobject]@{
            run = $i
            success = Get-JsonPropertyValue -Object $json -Name "success" -DefaultValue $false
            file = Get-JsonPropertyValue -Object $json -Name "file" -DefaultValue ""
            starting_offset = Get-JsonPropertyValue -Object $json -Name "starting_offset" -DefaultValue 0
            next_offset = Get-JsonPropertyValue -Object $json -Name "next_offset" -DefaultValue 0
            processed_this_run = Get-JsonPropertyValue -Object $json -Name "processed_this_run" -DefaultValue 0
            inserted_this_run = Get-JsonPropertyValue -Object $json -Name "inserted_this_run" -DefaultValue 0
            batches = Get-JsonPropertyValue -Object $json -Name "batches" -DefaultValue 0
            limit = Get-JsonPropertyValue -Object $json -Name "limit" -DefaultValue 0
            error = Get-JsonPropertyValue -Object $json -Name "error" -DefaultValue ""
        }

        $ImportRows.Add($row) | Out-Null
        $row | Format-List

        Invoke-SpineEvent -EventType "heartbeat" -Status "running" -SignalKey "epg_db_import_loop_heartbeat" -Disposition "import_loop_running" -Metrics ([pscustomobject]@{
            run_number = $i
            max_import_runs = $MaxImportRuns
            starting_offset = $row.starting_offset
            next_offset = $row.next_offset
            processed_this_run = $row.processed_this_run
            inserted_this_run = $row.inserted_this_run
            batches = $row.batches
            import_limit = $ImportLimit
        }) -ReportCsvPath $ReportCsv

        if (-not [string]::IsNullOrWhiteSpace([string]$row.error)) {
            throw "EPG import error: $($row.error)"
        }

        if ([int]$row.processed_this_run -lt 1) {
            Write-Host "[import_loop] Import complete."
            $completedNaturally = $true
            break
        }

        if ($i -eq $MaxImportRuns -and [int]$row.processed_this_run -ge $ImportLimit) {
            $maxRunsReachedWithFullBatch = $true
        }

        Start-Sleep -Seconds $SleepSeconds
    }

    $ImportRows | Export-Csv -Path $ReportCsv -NoTypeInformation -Encoding UTF8

    if ($maxRunsReachedWithFullBatch -and $FailIfMaxRunsReachedWithFullBatch) {
        Invoke-SpineEvent -EventType "signal" -Status "fail" -SignalKey "epg_db_import_incomplete" -Disposition "max_runs_reached_with_full_batch" -Metrics (Get-ImportAggregateMetrics) -ReportCsvPath $ReportCsv
        throw "MaxImportRuns reached while last batch was full. Import may be incomplete. Increase -MaxImportRuns or rerun with -NoReset."
    }

    $freshness = $null
    if (-not $SkipDbFreshnessCheck) {
        $freshness = Invoke-DbFreshnessCheck -RepoRoot $RepoRoot
        $freshness | Format-List

        Invoke-SpineEvent -EventType "heartbeat" -Status "running" -SignalKey "epg_db_import_freshness_checked" -Disposition "freshness_checked" -Metrics $freshness -ReportCsvPath $ReportCsv
    }

    if (-not $SkipLiveCacheEnrichment) {
        $shouldEnrich = $true
        if ($null -ne $freshness) {
            $current = [int]$freshness.currently_active_programs
            $future = [int]$freshness.future_programs
            $shouldEnrich = ($current -gt 0 -or $future -gt 0)
        }

        if ($shouldEnrich) {
            Invoke-LiveCacheEnrichment -RepoRoot $RepoRoot -MacUserId $MacUserId | Out-Null

            Invoke-SpineEvent -EventType "signal" -Status "running" -SignalKey "epg_live_cache_enriched" -Disposition "enrichment_called" -Metrics ([pscustomobject]@{
                mac_user_id = $MacUserId
                freshness = $freshness
            }) -ReportCsvPath $ReportCsv
        }
        else {
            Write-Host "[live_cache_enrichment] Skipped: no current or future EPG rows."

            Invoke-SpineEvent -EventType "signal" -Status "skipped" -SignalKey "epg_pipeline_stale" -Disposition "no_current_or_future_epg_to_enrich" -Metrics $freshness -ReportCsvPath $ReportCsv
        }
    }

    $disposition = if ($maxRunsReachedWithFullBatch) { "import_may_need_continuation" } else { "db_import_completed" }

    $summary = [pscustomobject]@{
        run_id = $RunId
        worker_key = $WorkerKey
        stage_key = $StageKey
        status = "pass"
        disposition = $disposition
        environment = $Environment
        reset_ran = (-not $NoReset)
        reset = $resetJson
        report_csv = $ReportCsv
        summary_json = $SummaryJson
        import = Get-ImportAggregateMetrics
        freshness = $freshness
        completed_naturally = $completedNaturally
        max_runs_reached_with_full_batch = $maxRunsReachedWithFullBatch
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8

    $finalMetrics = [pscustomobject]@{
        import = Get-ImportAggregateMetrics
        freshness = $freshness
        completed_naturally = $completedNaturally
        max_runs_reached_with_full_batch = $maxRunsReachedWithFullBatch
        mac_user_id = $MacUserId
    }

    Invoke-SpineEvent -EventType "signal" -Status "pass" -SignalKey "epg_db_import_completed" -Disposition $disposition -Metrics $finalMetrics -ReportCsvPath $ReportCsv -SummaryJsonPath $SummaryJson

    $summary | Format-List run_id,worker_key,stage_key,status,disposition,report_csv,summary_json
    exit 0
}
catch {
    $message = $_.Exception.Message

    $summary = [pscustomobject]@{
        run_id = $RunId
        worker_key = $WorkerKey
        stage_key = $StageKey
        status = "fail"
        disposition = "db_import_failed"
        environment = $Environment
        error = $message
        report_csv = $ReportCsv
        summary_json = $SummaryJson
        import = Get-ImportAggregateMetrics
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8

    Invoke-SpineEvent -EventType "signal" -Status "fail" -SignalKey "epg_db_import_failed" -Disposition "db_import_failed" -Metrics (Get-ImportAggregateMetrics) -ReportCsvPath $ReportCsv -SummaryJsonPath $SummaryJson -ErrorMessage $message

    Write-Error $message
    exit 1
}
