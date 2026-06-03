<#
.SYNOPSIS
  EPG Gate 3: Import/upsert database only.

.DESCRIPTION
  Retries the database import/upsert loop against the existing server-side EPG file:
    /home/xpdgxfsp/public_html/miratv.club/automated/epg.xml

  This worker does not download and does not upload.

  Use this when the XML file is already on the server and only the DB upsert/import
  needs to be retried or continued.

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
    [switch]$FailIfMaxRunsReachedWithFullBatch
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
    }
}

try {
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
                break
            }
            catch {
                $lastResetError = $_.Exception.Message
                Write-Host "[import_reset] Not ready yet: $lastResetError" -ForegroundColor Yellow

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
        throw "MaxImportRuns reached while last batch was full. Import may be incomplete. Increase -MaxImportRuns or rerun with -NoReset."
    }

    $freshness = $null
    if (-not $SkipDbFreshnessCheck) {
        $freshness = Invoke-DbFreshnessCheck -RepoRoot $RepoRoot
        $freshness | Format-List
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
        }
        else {
            Write-Host "[live_cache_enrichment] Skipped: no current or future EPG rows."
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
    Write-Error $message
    exit 1
}
