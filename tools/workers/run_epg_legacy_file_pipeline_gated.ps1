<#
.SYNOPSIS
  MiraTV gated legacy EPG file pipeline runner.

.DESCRIPTION
  Runs the proven large-file EPG flow without infinite loops:
    1. Run local XMLTV download script.
    2. Validate local epg.xml exists and looks like XMLTV.
    3. Run local FTP/upload script from its own folder.
    4. Smoke-test import_epg.php reset ONCE with limit=1, with short retries for server file visibility.
    5. Stop immediately if importer returns error JSON, missing file, or no success field.
    6. Run bounded import loop until processed_this_run < 1 or MaxRuns reached.
    7. Optionally check DB freshness through DbQuery.psm1.
    8. Optionally call Live cache enrichment proc if DB has current/future EPG.

.NOTES
  Do not commit local trigger scripts that contain provider URL, FTP password, or ingest token.
  This runner expects secrets in local scripts and/or environment variables.

  Important:
  - import_epg.php reads /home/xpdgxfsp/public_html/miratv.club/automated/epg.xml.
  - If reset returns { error: "File not found" }, this runner stops before the import loop.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$DownloadScript = "C:\miratv_ingest\trigger to download epg-xml to c miratv_ingest-export step 1.ps1",
    [string]$UploadScript = "C:\miratv_ingest\trigger to upload epg file to miratv- automated directory step 2.ps1",
    [string]$LocalEpgPath = "C:\miratv_ingest\export\epg.xml",
    [string]$ImportUrl = "https://miratv.club/_ingest/import_epg.php",
    [string]$IngestToken = "",
    [int]$ImportLimit = 19000,
    [int]$MaxImportRuns = 20,
    [int]$SleepSeconds = 1,
    [int]$ImportResetRetryCount = 10,
    [int]$ImportResetRetrySeconds = 6,
    [switch]$SkipDownload,
    [switch]$SkipUpload,
    [switch]$SkipDbFreshnessCheck,
    [switch]$SkipLiveCacheEnrichment,
    [int]$MacUserId = 6,
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}

$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-legacy-file-pipeline-$Stamp"
$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_legacy_file_pipeline"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$ReportCsv = Join-Path $ReportDir "epg_legacy_file_pipeline_$Stamp.csv"
$SummaryJson = Join-Path $ReportDir "epg_legacy_file_pipeline_summary_$Stamp.json"

$Steps = New-Object System.Collections.Generic.List[object]
$ImportRows = New-Object System.Collections.Generic.List[object]

function Add-StepResult {
    param(
        [string]$Step,
        [string]$Status,
        [string]$Disposition,
        [object]$Data = $null
    )

    $Steps.Add([pscustomobject]@{
        run_id = $RunId
        step = $Step
        status = $Status
        disposition = $Disposition
        event_utc = (Get-Date).ToUniversalTime().ToString("o")
        data_json = if ($null -ne $Data) { ($Data | ConvertTo-Json -Depth 8 -Compress) } else { "" }
    }) | Out-Null
}

function Test-JsonProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JsonPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if (Test-JsonProperty -Object $Object -Name $Name) {
        return $Object.$Name
    }

    return $DefaultValue
}

function Invoke-LocalScript {
    param(
        [string]$Path,
        [string]$StepName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$StepName script not found: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $scriptDir = Split-Path -Parent $resolvedPath

    Write-Host "[$StepName] Running: $resolvedPath"
    Write-Host "[$StepName] Working directory: $scriptDir"

    Push-Location $scriptDir
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $resolvedPath

        if ($LASTEXITCODE -ne 0) {
            throw "$StepName failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
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
    param(
        [object]$Json,
        [string]$StepName,
        [switch]$RequireProcessed
    )

    if ($null -eq $Json) {
        throw "$StepName returned no JSON."
    }

    $errorValue = Get-JsonPropertyValue -Object $Json -Name "error" -DefaultValue ""
    if (-not [string]::IsNullOrWhiteSpace([string]$errorValue)) {
        $fileValue = Get-JsonPropertyValue -Object $Json -Name "file" -DefaultValue ""
        throw "$StepName returned error: $errorValue file=$fileValue"
    }

    if (-not (Test-JsonProperty -Object $Json -Name "success")) {
        $shape = ($Json.PSObject.Properties.Name -join ",")
        throw "$StepName response missing success property. Shape=$shape"
    }

    if ($Json.success -ne $true) {
        throw "$StepName returned success=false."
    }

    if ($RequireProcessed) {
        $processed = [int](Get-JsonPropertyValue -Object $Json -Name "processed_this_run" -DefaultValue 0)
        if ($processed -lt 1) {
            throw "$StepName processed_this_run < 1."
        }
    }
}

function Test-LocalXmlTvFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "EPG XML file missing: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1024) {
        throw "EPG XML file is unexpectedly small: $($item.Length) bytes"
    }

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore

    $minStart = $null
    $maxStart = $null
    $minStop = $null
    $maxStop = $null
    $programmeCount = 0
    $maxScan = 250000

    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element -and $reader.Name -eq "programme") {
                $programmeCount++
                $startRaw = $reader.GetAttribute("start")
                $stopRaw = $reader.GetAttribute("stop")

                if ($startRaw) {
                    $digits = ($startRaw -replace '[^\d]', '')
                    if ($digits.Length -ge 14) {
                        $start14 = $digits.Substring(0, 14)
                        if (-not $minStart -or $start14 -lt $minStart) { $minStart = $start14 }
                        if (-not $maxStart -or $start14 -gt $maxStart) { $maxStart = $start14 }
                    }
                }

                if ($stopRaw) {
                    $digits = ($stopRaw -replace '[^\d]', '')
                    if ($digits.Length -ge 14) {
                        $stop14 = $digits.Substring(0, 14)
                        if (-not $minStop -or $stop14 -lt $minStop) { $minStop = $stop14 }
                        if (-not $maxStop -or $stop14 -gt $maxStop) { $maxStop = $stop14 }
                    }
                }

                if ($programmeCount -ge $maxScan) { break }
            }
        }
    }
    finally {
        $reader.Close()
    }

    if ($programmeCount -lt 1) {
        throw "No programme nodes found in XMLTV file."
    }

    return [pscustomobject]@{
        full_name = $item.FullName
        length_mb = [math]::Round($item.Length / 1MB, 2)
        last_write_time = $item.LastWriteTime.ToString("s")
        scanned_programme_count = $programmeCount
        min_start_raw = $minStart
        max_start_raw = $maxStart
        min_stop_raw = $minStop
        max_stop_raw = $maxStop
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
    param(
        [string]$RepoRoot,
        [int]$MacUserId
    )

    $module = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    Import-Module $module -Force

    $sql = "CALL xpdgxfsp_content.sp_enrich_live_screen_cache_epg($MacUserId, 'live');"
    return Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 300
}

try {
    Add-StepResult -Step "start" -Status "running" -Disposition "pipeline_started" -Data ([pscustomobject]@{
        environment = $Environment
        local_epg_path = $LocalEpgPath
        import_url = $ImportUrl
        import_limit = $ImportLimit
        max_import_runs = $MaxImportRuns
        import_reset_retry_count = $ImportResetRetryCount
        import_reset_retry_seconds = $ImportResetRetrySeconds
    })

    if (-not $SkipDownload) {
        Invoke-LocalScript -Path $DownloadScript -StepName "download"
        Add-StepResult -Step "download" -Status "pass" -Disposition "download_script_completed" -Data @{ path = $DownloadScript }
    }
    else {
        Add-StepResult -Step "download" -Status "skip" -Disposition "download_skipped"
    }

    $xmlInfo = Test-LocalXmlTvFile -Path $LocalEpgPath
    $xmlInfo | Format-List
    Add-StepResult -Step "validate_local_xml" -Status "pass" -Disposition "xmltv_file_valid" -Data $xmlInfo

    if (-not $SkipUpload) {
        Invoke-LocalScript -Path $UploadScript -StepName "upload"
        Add-StepResult -Step "upload" -Status "pass" -Disposition "upload_script_completed" -Data @{ path = $UploadScript }
    }
    else {
        Add-StepResult -Step "upload" -Status "skip" -Disposition "upload_skipped"
    }

    $token = Get-SecretToken -Provided $IngestToken

    Write-Host "[import_reset] Resetting import offset once with limit=1"

    $resetJson = $null
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

    Add-StepResult -Step "import_reset" -Status "pass" -Disposition "reset_once_completed" -Data $resetJson

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
            break
        }

        Start-Sleep -Seconds $SleepSeconds
    }

    $ImportRows | Export-Csv -Path $ReportCsv -NoTypeInformation -Encoding UTF8
    Add-StepResult -Step "import_loop" -Status "pass" -Disposition "bounded_import_loop_completed" -Data @{ report_csv = $ReportCsv; runs = $ImportRows.Count }

    $freshness = $null
    if (-not $SkipDbFreshnessCheck) {
        $freshness = Invoke-DbFreshnessCheck -RepoRoot $RepoRoot
        $freshness | Format-List
        Add-StepResult -Step "db_freshness" -Status "pass" -Disposition "freshness_checked" -Data $freshness
    }

    if (-not $SkipLiveCacheEnrichment) {
        $shouldEnrich = $true
        if ($null -ne $freshness) {
            $current = [int]$freshness.currently_active_programs
            $future = [int]$freshness.future_programs
            $shouldEnrich = ($current -gt 0 -or $future -gt 0)
        }

        if ($shouldEnrich) {
            $enrich = Invoke-LiveCacheEnrichment -RepoRoot $RepoRoot -MacUserId $MacUserId
            Add-StepResult -Step "live_cache_enrichment" -Status "pass" -Disposition "enrichment_called" -Data $enrich
        }
        else {
            Add-StepResult -Step "live_cache_enrichment" -Status "skip" -Disposition "no_current_or_future_epg_to_enrich"
        }
    }

    Add-StepResult -Step "stop" -Status "pass" -Disposition "pipeline_completed"

    $summary = [pscustomobject]@{
        run_id = $RunId
        status = "pass"
        disposition = "pipeline_completed"
        report_csv = $ReportCsv
        summary_json = $SummaryJson
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        import_runs = $ImportRows.Count
        steps = $Steps
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8
    $summary | Format-List run_id,status,disposition,report_csv,summary_json,import_runs
    exit 0
}
catch {
    $message = $_.Exception.Message
    Add-StepResult -Step "error" -Status "fail" -Disposition "pipeline_failed" -Data @{ message = $message }

    $summary = [pscustomobject]@{
        run_id = $RunId
        status = "fail"
        disposition = "pipeline_failed"
        error = $message
        report_csv = $ReportCsv
        summary_json = $SummaryJson
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        import_runs = $ImportRows.Count
        steps = $Steps
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8
    Write-Error $message
    exit 1
}
