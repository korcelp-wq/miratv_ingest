<#
.SYNOPSIS
  Run server-side EPG import queue after XML upload.

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
    [string]$ImportUrl = "https://miratv.club/_ingest/import_epg.php",
    [int]$Limit = 5000,
    [int]$MaxRuns = 200,
    [int]$SleepSeconds = 2,
    [switch]$Reset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "run_epg_server_import_queue"
$Component = "epg_server_import_queue"
$KillSwitchName = "ENABLE_EPG_SERVER_IMPORT_QUEUE"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_server_import_queue"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_server_import_queue"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$SummaryPath = Join-Path $ReportDir "epg_server_import_queue_summary_$Stamp.json"
$RunCsvPath = Join-Path $ReportDir "epg_server_import_queue_runs_$Stamp.csv"
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

function Get-JsonInt {
    param([object]$Json, [string[]]$Names)

    foreach ($name in $Names) {
        if ($Json.PSObject.Properties.Name -contains $name) {
            $value = 0
            [void][int]::TryParse([string]$Json.$name, [ref]$value)
            return $value
        }
    }

    return 0
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    $token = [Environment]::GetEnvironmentVariable("EPG_IMPORT_TOKEN")
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "EPG_IMPORT_TOKEN is not set."
    }

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        import_url = $ImportUrl
        limit = $Limit
        max_runs = $MaxRuns
        reset_requested = [bool]$Reset
        provider_calls = $true
        db_writes = $true
    })

    $runRows = New-Object System.Collections.Generic.List[object]
    $totalProcessed = 0
    $totalInserted = 0
    $totalUpdated = 0
    $totalSkipped = 0
    $done = $false
    $lastBody = ""
    $lastStatus = ""

    for ($i = 1; $i -le $MaxRuns; $i++) {
        Emit-Heartbeat -Status "run_$i"

        $url = "${ImportUrl}?limit=$Limit"
        if ($Reset -and $i -eq 1) {
            $url = "$url&reset=1"
        }

        $response = Invoke-WebRequest `
            -Uri $url `
            -Headers @{ "X-Ingest-Token" = $token } `
            -UseBasicParsing `
            -TimeoutSec 300

        $lastBody = [string]$response.Content

        try {
            $json = $lastBody | ConvertFrom-Json
        }
        catch {
            throw "Import endpoint returned non-JSON response: $lastBody"
        }

        $processed = Get-JsonInt -Json $json -Names @("processed","last_chunk_processed","rows_processed")
        $inserted = Get-JsonInt -Json $json -Names @("inserted","last_chunk_inserted","rows_inserted")
        $updated = Get-JsonInt -Json $json -Names @("updated","last_chunk_updated","rows_updated")
        $skipped = Get-JsonInt -Json $json -Names @("skipped","last_chunk_skipped","rows_skipped")

        $totalProcessed += $processed
        $totalInserted += $inserted
        $totalUpdated += $updated
        $totalSkipped += $skipped

        $done = (($json.PSObject.Properties.Name -contains "done") -and [bool]$json.done)
        $lastStatus = if ($done) { "done" } else { "running" }

        $runRows.Add([pscustomobject][ordered]@{
            run_number = $i
            processed = $processed
            inserted = $inserted
            updated = $updated
            skipped = $skipped
            done = $done
            response_excerpt = if ($lastBody.Length -gt 500) { $lastBody.Substring(0,500) } else { $lastBody }
        })

        Write-JobLog -EventName "import_run_completed" -Status $lastStatus -Data ([ordered]@{
            run_number = $i
            processed = $processed
            inserted = $inserted
            updated = $updated
            skipped = $skipped
            done = $done
        })

        if ($done -or ($processed -le 0 -and $inserted -le 0 -and $updated -le 0)) {
            $done = $true
            break
        }

        Start-Sleep -Seconds $SleepSeconds
    }

    $runRows | Export-Csv -NoTypeInformation -Path $RunCsvPath -Encoding UTF8

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        import_url = $ImportUrl
        limit = $Limit
        max_runs = $MaxRuns
        runs_completed = $runRows.Count
        total_processed = $totalProcessed
        total_inserted = $totalInserted
        total_updated = $totalUpdated
        total_skipped = $totalSkipped
        done = $done
        provider_calls = $true
        db_writes = $true
        duration_ms = Get-DurationMs -Start $StartedAt
        run_csv_path = $RunCsvPath
        status = if ($done) { "pass" } else { "warning" }
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_server_import_queue_completed" -SignalValue $summary.status -Payload $summary
    Write-JobLog -EventName "job_completed" -Status $summary.status -Data $summary

    Write-Output "OK: EPG server import queue completed. runs=$($runRows.Count) processed=$totalProcessed inserted=$totalInserted updated=$totalUpdated skipped=$totalSkipped done=$done summary=$SummaryPath"
}
catch {
    $errorSummary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        import_url = $ImportUrl
        limit = $Limit
        max_runs = $MaxRuns
        done = $false
        last_error = $_.Exception.Message
        provider_calls = $true
        db_writes = $true
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $errorSummary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_server_import_queue_completed" -SignalValue "failed" -Payload $errorSummary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $errorSummary

    throw
}
