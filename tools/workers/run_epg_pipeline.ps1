<#
.SYNOPSIS
  Run governed EPG XML pipeline.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [int]$ImportLimit = 5000,
    [int]$MaxImportRuns = 200,
    [switch]$ResetImport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "run_epg_pipeline"
$Component = "epg_pipeline"
$KillSwitchName = "ENABLE_EPG_PIPELINE"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_pipeline"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_pipeline"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$SummaryPath = Join-Path $ReportDir "epg_pipeline_summary_$Stamp.json"
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

function Invoke-Step {
    param(
        [string]$StepName,
        [scriptblock]$Command
    )

    $stepStart = Get-Date
    Write-Host "EPG PIPELINE STEP: $StepName"
    Emit-Heartbeat -Status $StepName
    Write-JobLog -EventName "step_started" -Status "running" -Data ([ordered]@{
        step_name = $StepName
    })

    & $Command

    Write-JobLog -EventName "step_completed" -Status "pass" -Data ([ordered]@{
        step_name = $StepName
        duration_ms = Get-DurationMs -Start $stepStart
    })
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        import_limit = $ImportLimit
        max_import_runs = $MaxImportRuns
        reset_import = [bool]$ResetImport
        provider_calls = $true
        db_writes = $true
    })

    Invoke-Step -StepName "pull_epg_xml" -Command {
        pwsh -NoProfile -ExecutionPolicy Bypass `
            -File ".\tools\workers\pull_epg_xml.ps1" `
            -Environment $Environment `
            -Provider $Provider
    }

    Invoke-Step -StepName "upload_epg_xml_to_server" -Command {
        pwsh -NoProfile -ExecutionPolicy Bypass `
            -File ".\tools\workers\upload_epg_xml_to_server.ps1" `
            -Environment $Environment `
            -Provider $Provider
    }

    Invoke-Step -StepName "run_epg_server_import_queue" -Command {
        $resetArgs = @()
        if ($ResetImport) {
            $resetArgs = @("-Reset")
        }

        pwsh -NoProfile -ExecutionPolicy Bypass `
            -File ".\tools\workers\run_epg_server_import_queue.ps1" `
            -Environment $Environment `
            -Provider $Provider `
            -Limit $ImportLimit `
            -MaxRuns $MaxImportRuns `
            @resetArgs
    }

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        import_limit = $ImportLimit
        max_import_runs = $MaxImportRuns
        reset_import = [bool]$ResetImport
        provider_calls = $true
        db_writes = $true
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "pass"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_pipeline_completed" -SignalValue "pass" -Payload $summary
    Write-JobLog -EventName "job_completed" -Status "pass" -Data $summary

    Write-Output "OK: EPG pipeline completed. summary=$SummaryPath"
}
catch {
    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        import_limit = $ImportLimit
        max_import_runs = $MaxImportRuns
        reset_import = [bool]$ResetImport
        provider_calls = $true
        db_writes = $true
        duration_ms = Get-DurationMs -Start $StartedAt
        last_error = $_.Exception.Message
        status = "failed"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_pipeline_completed" -SignalValue "failed" -Payload $summary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $summary

    throw
}
