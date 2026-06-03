<#
.SYNOPSIS
  Read Master Control dashboard cards from the DB view.

.DESCRIPTION
  Hard-interface backup for the future web dashboard.

  Reads:
    xpdgxfsp_content.v_mc_dashboard_cards

  Writes:
    runtime\reports\master_control_dashboard_cards\master_control_dashboard_cards_*.csv
    runtime\reports\master_control_dashboard_cards\master_control_dashboard_cards_*.json
    runtime\reports\master_control_dashboard_cards\master_control_dashboard_cards_summary_*.json

  This worker is read-only:
    provider_calls = false
    db_writes = false

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$WorkerName = "get_master_control_dashboard_cards",
    [string]$Component = "master_control_dashboard",
    [string]$OutputRoot = "runtime/reports/master_control_dashboard_cards",
    [switch]$AsJson,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Stage = "init"

function Get-RepoRootLocal {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue
    if ($null -ne $resolved) { return $resolved.Path }
    return (Get-Location).Path
}

function New-RunIdLocal {
    param([string]$Prefix = "master-control-dashboard-cards")
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N").Substring(0, 16)
    return "$Prefix-$stamp-$guid"
}

function New-DirectoryLocal {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

$repoRoot = Get-RepoRootLocal
Set-Location $repoRoot

$script:RunId = New-RunIdLocal
$startedAt = Get-Date

$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$dbQueryModule = Join-Path $repoRoot "tools\common\DbQuery.psm1"
if (-not (Test-Path -LiteralPath $dbQueryModule)) {
    throw "DbQuery module not found: $dbQueryModule"
}
Import-Module $dbQueryModule -Force

$masterControlModule = Join-Path $repoRoot "tools\common\MasterControlDb.psm1"
if (Test-Path -LiteralPath $masterControlModule) {
    Import-Module $masterControlModule -Force
}

try {
    $script:Stage = "query_dashboard_cards"

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_started" `
            -Status "started" `
            -Data @{
                event_message = "Reading Master Control dashboard cards."
                provider_calls = $false
                db_writes = $false
                view_name = "xpdgxfsp_content.v_mc_dashboard_cards"
            } | Out-Null
    }

    if (Get-Command Get-McDashboardCardSql -ErrorAction SilentlyContinue) {
        $sql = Get-McDashboardCardSql
    }
    else {
        $sql = @"
SELECT
  card,
  status,
  lane_or_component,
  provider_label,
  primary_count,
  secondary_count,
  metric_label,
  event_time,
  artifact,
  ingest_id
FROM xpdgxfsp_content.v_mc_dashboard_cards
ORDER BY
  FIELD(card,'spine_runner','delta_plan','governed_import_runner','vod_preview','vod_apply','epg_db_import');
"@
    }

    $result = Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120
    $cards = @($result.rows)

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $outputRootFull "master_control_dashboard_cards_$stamp.csv"
    $reportJson = Join-Path $outputRootFull "master_control_dashboard_cards_$stamp.json"
    $summaryJson = Join-Path $outputRootFull "master_control_dashboard_cards_summary_$stamp.json"

    $cards | Export-Csv -LiteralPath $reportCsv -NoTypeInformation -Encoding UTF8
    $cards | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportJson -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
    $failedCards = @($cards | Where-Object { $_.status -ne "pass" })

    $summary = [ordered]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        status = if ($failedCards.Count -eq 0 -and $cards.Count -gt 0) { "pass" } elseif ($cards.Count -gt 0) { "warning" } else { "fail" }
        disposition = if ($cards.Count -gt 0) { "dashboard_cards_read" } else { "dashboard_cards_empty" }
        provider_calls = $false
        db_reads = $true
        db_writes = $false
        card_count = $cards.Count
        failed_card_count = $failedCards.Count
        duration_ms = $durationMs
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status $summary.status `
            -Data @{
                event_message = "Master Control dashboard cards read."
                card_count = $cards.Count
                failed_card_count = $failedCards.Count
                duration_ms = $durationMs
                report_csv = $reportCsv
                summary_json = $summaryJson
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "master_control_dashboard_cards_read" `
            -P0Item "P0.5" `
            -SignalValue $summary.status `
            -Status $summary.status `
            -AllowedValues "pass|warning|fail" `
            -SourceTableOrEndpoint "xpdgxfsp_content.v_mc_dashboard_cards" `
            -Data @{
                dashboard_panel = "Master Control"
                widget_key = "master.control.dashboard.cards"
                owner = "Content Ops"
                card_count = $cards.Count
                failed_card_count = $failedCards.Count
            } | Out-Null
    }

    if ($AsJson) {
        [ordered]@{
            status = $summary.status
            endpoint_version = "master_control_dashboard_cards_ps_20260602_v1"
            generated_at_utc = $summary.generated_at_utc
            cards = $cards
            summary = $summary
        } | ConvertTo-Json -Depth 20
    }
    elseif (-not $Quiet) {
        Write-Host "OK: Master Control dashboard cards read. status=$($summary.status) cards=$($cards.Count) db_writes=False"
        Write-Host "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        $cards | Format-Table card,status,lane_or_component,provider_label,primary_count,secondary_count,metric_label -AutoSize
        [pscustomobject]$summary
    }
    else {
        [pscustomobject]$summary
    }
}
catch {
    $errorMessage = "stage=$script:Stage; error=$($_.Exception.Message)"

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_failed" `
            -Status "fail" `
            -Data @{
                event_message = "Master Control dashboard card read failed."
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: Master Control dashboard card read failed. run_id=$script:RunId $errorMessage"
    exit 1
}

