<#
.SYNOPSIS
  EPG Gate 2: Upload XMLTV file only.

.DESCRIPTION
  Validates the local XMLTV file exists, calls the local/ignored upload script,
  then smoke-tests import_epg.php with reset=1&limit=1 to prove the server can read the uploaded file.

  This worker does not download and does not perform the full DB import/upsert loop.

.NOTES
  Keep FTP credentials/secrets in local/epg/02_upload_epg_xml_to_automated.ps1.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$UploadScript = ".\local\epg\02_upload_epg_xml_to_automated.ps1",
    [string]$LocalEpgPath = "C:\miratv_ingest\export\epg.xml",
    [string]$ImportUrl = "https://miratv.club/_ingest/import_epg.php",
    [string]$IngestToken = "",
    [string]$RepoRoot = "",
    [int]$SmokeRetryCount = 10,
    [int]$SmokeRetrySeconds = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}

$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-upload-$Stamp"
$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_upload"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$SummaryJson = Join-Path $ReportDir "epg_upload_summary_$Stamp.json"

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

try {
    if (-not (Test-Path -LiteralPath $LocalEpgPath)) {
        throw "Local EPG file missing: $LocalEpgPath"
    }

    $localItem = Get-Item -LiteralPath $LocalEpgPath
    if ($localItem.Length -lt 1024) {
        throw "Local EPG file is too small: $($localItem.Length) bytes"
    }

    Invoke-LocalScript -Path $UploadScript -StepName "upload"

    $token = Get-SecretToken -Provided $IngestToken
    $smokeJson = $null
    $lastError = ""
    $smokeOk = $false

    for ($attempt = 1; $attempt -le $SmokeRetryCount; $attempt++) {
        Write-Host "[upload_smoke] Attempt $attempt / $SmokeRetryCount"
        try {
            $smokeJson = Invoke-ImportEndpoint -Url $ImportUrl -Token $token -Query @{ reset = 1; limit = 1 } -TimeoutSec 120
            $smokeJson | Format-List
            Assert-ImportResponseOk -Json $smokeJson -StepName "upload_smoke" -RequireProcessed
            $smokeOk = $true
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host "[upload_smoke] Not ready: $lastError" -ForegroundColor Yellow
            if ($attempt -lt $SmokeRetryCount) { Start-Sleep -Seconds $SmokeRetrySeconds }
        }
    }

    if (-not $smokeOk) {
        throw "upload smoke test failed after $SmokeRetryCount attempts. Last error: $lastError"
    }

    $summary = [pscustomobject]@{
        run_id = $RunId
        worker_key = "epg_upload_xml"
        stage_key = "media_refresh.epg.upload"
        status = "pass"
        disposition = "upload_completed_importer_readable"
        environment = $Environment
        local_epg_path = $LocalEpgPath
        local_epg_length_mb = [math]::Round($localItem.Length / 1MB, 2)
        smoke = $smokeJson
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8
    $summary | Format-List run_id,worker_key,stage_key,status,disposition
    exit 0
}
catch {
    $summary = [pscustomobject]@{
        run_id = $RunId
        worker_key = "epg_upload_xml"
        stage_key = "media_refresh.epg.upload"
        status = "fail"
        disposition = "upload_failed"
        environment = $Environment
        error = $_.Exception.Message
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8
    Write-Error $_.Exception.Message
    exit 1
}
