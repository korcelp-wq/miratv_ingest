<#
.SYNOPSIS
    Run the governed provider snapshot spine for one MiraTV account.

.DESCRIPTION
    Orchestrates the safe provider snapshot workflow:

      1. inspect_provider_account_context
      2. build_provider_live_categories_snapshot
      3. build_provider_vod_categories_snapshot
      4. build_provider_series_categories_snapshot
      5. build_provider_live_streams_snapshot
      6. build_provider_vod_streams_snapshot
      7. build_provider_series_streams_snapshot
      8. plan_provider_snapshot_delta

    This runner:
      - DOES call provider APIs through the snapshot workers.
      - DOES NOT import provider inventory to database.
      - DOES NOT run get_series_info.
      - DOES NOT run EPG import.
      - Writes existing CSV/JSON files as debug/fallback artifacts.
      - Writes Master Control DB summary/step rows directly when MasterControlDb.psm1 is available.
      - Stops on first failed child worker unless -ContinueOnError is used.

    Intended clean-repo location:
      tools\workers\run_provider_snapshot_spine.ps1
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "run_provider_snapshot_spine",
    [string]$Component = "provider_snapshot_spine",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_SPINE_RUNNER",

    [int]$MacUserId = 6,
    [string]$ProviderLabel = "",

    [string]$OutputRoot = "runtime/reports/provider_snapshot_spine_runner",

    [switch]$SkipAccountInspection,
    [switch]$ContinueOnError,
    [switch]$SkipMcDbLog
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
    param([string]$Prefix = "provider-snapshot-spine-runner")

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N")
    return "$Prefix-$stamp-$guid"
}

function New-DirectoryLocal {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Test-KillSwitchCompatible {
    param(
        [string]$Name,
        [bool]$DefaultEnabled = $true
    )

    $cmd = Get-Command Test-KillSwitch -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $DefaultEnabled }

    $result = Test-KillSwitch -Name $Name -DefaultEnabled $DefaultEnabled
    if ($result -is [bool]) { return [bool]$result }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "enabled")) {
        return [bool]$result.enabled
    }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "is_enabled")) {
        return [bool]$result.is_enabled
    }

    return $DefaultEnabled
}

function Invoke-ChildWorkerLocal {
    param(
        [string]$RepoRoot,
        [string]$RelativePath,
        [string]$StepName,
        [string]$Environment,
        [int]$MacUserId,
        [string]$ProviderLabel
    )

    $fullPath = Join-Path $RepoRoot $RelativePath
    $startedAt = Get-Date

    if (-not (Test-Path -LiteralPath $fullPath)) {
        return [pscustomobject]@{
            step_name = $StepName
            worker_path = $RelativePath
            exists = $false
            exit_code = 999
            status = "missing"
            duration_ms = 0
            stdout_tail = ""
            stderr_tail = "Worker file missing: $RelativePath"
        }
    }

    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $fullPath,
        "-Environment", $Environment,
        "-MacUserId", ([string]$MacUserId),
        "-ProviderLabel", $ProviderLabel
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "pwsh"

    foreach ($arg in $argumentList) {
        [void]$psi.ArgumentList.Add($arg)
    }

    $psi.WorkingDirectory = $RepoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    $stdoutLines = @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $stderrLines = @($stderr -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $stdoutTail = (($stdoutLines | Select-Object -Last 8) -join " | ")
    $stderrTail = (($stderrLines | Select-Object -Last 8) -join " | ")

    return [pscustomobject]@{
        step_name = $StepName
        worker_path = $RelativePath
        exists = $true
        exit_code = [int]$process.ExitCode
        status = if ($process.ExitCode -eq 0) { "pass" } else { "fail" }
        duration_ms = $durationMs
        stdout_tail = $stdoutTail
        stderr_tail = $stderrTail
    }
}

function Get-ResolvedProviderLabelFromChildOutputLocal {
    param([string]$StdoutTail)

    if ([string]::IsNullOrWhiteSpace($StdoutTail)) {
        return ""
    }

    $match = [regex]::Match($StdoutTail, 'summary_json="([^"]+)"')
    if (-not $match.Success) {
        return ""
    }

    $summaryPath = $match.Groups[1].Value
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        return ""
    }

    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        return [string]$summary.resolved_provider_label
    }
    catch {
        return ""
    }
}

function Convert-ObjectToHashtableLocal {
    param([Parameter(Mandatory = $true)][object]$Object)

    $hash = @{}

    foreach ($prop in $Object.PSObject.Properties) {
        $hash[$prop.Name] = $prop.Value
    }

    return $hash
}

function Initialize-MasterControlDbLocal {
    param(
        [string]$RepoRoot,
        [bool]$Skip
    )

    $result = [ordered]@{
        available = $false
        error = ""
    }

    if ($Skip) {
        $result.error = "Master Control DB logging skipped by switch."
        return [pscustomobject]$result
    }

    try {
        $dbQueryModulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
        if (Test-Path -LiteralPath $dbQueryModulePath) {
            Import-Module $dbQueryModulePath -Force
        }

        $mcDbModulePath = Join-Path $RepoRoot "tools\common\MasterControlDb.psm1"
        if (-not (Test-Path -LiteralPath $mcDbModulePath)) {
            $result.error = "MasterControlDb module not found: $mcDbModulePath"
            return [pscustomobject]$result
        }

        Import-Module $mcDbModulePath -Force
        $result.available = [bool](Get-Command Write-McProviderSnapshotSpineSummary -ErrorAction SilentlyContinue)

        if (-not $result.available) {
            $result.error = "MasterControlDb module loaded, but Write-McProviderSnapshotSpineSummary is unavailable."
        }
    }
    catch {
        $result.available = $false
        $result.error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Write-MasterControlDbForSpineLocal {
    param(
        [object]$Summary,
        [object[]]$Rows,
        [string]$SummaryJson,
        [string]$ReportCsv
    )

    $summaryHash = Convert-ObjectToHashtableLocal -Object $Summary

    $summaryFile = Get-Item -LiteralPath $SummaryJson
    $summaryMeta = New-McSourceMeta `
        -SourceFilePath $summaryFile.FullName `
        -SourceFilePattern "provider_snapshot_spine_runner_summary_TIMESTAMP.json" `
        -SourceFileSha256 ((Get-FileHash -LiteralPath $summaryFile.FullName -Algorithm SHA256).Hash) `
        -SourceFileLastWriteUtc $summaryFile.LastWriteTimeUtc.ToString("o")

    Write-McProviderSnapshotSpineSummary `
        -Summary $summaryHash `
        -SourceMeta $summaryMeta | Out-Null

    $reportFile = Get-Item -LiteralPath $ReportCsv
    $reportMeta = New-McSourceMeta `
        -SourceFilePath $reportFile.FullName `
        -SourceFilePattern "provider_snapshot_spine_runner_report_TIMESTAMP.csv" `
        -SourceFileSha256 ((Get-FileHash -LiteralPath $reportFile.FullName -Algorithm SHA256).Hash) `
        -SourceFileLastWriteUtc $reportFile.LastWriteTimeUtc.ToString("o")

    foreach ($row in $Rows) {
        $stepHash = Convert-ObjectToHashtableLocal -Object $row

        Write-McProviderSnapshotSpineStep `
            -StepRow $stepHash `
            -SourceMeta $reportMeta | Out-Null
    }
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal
$ProviderLabelForChildren = $ProviderLabel
$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$mcDb = Initialize-MasterControlDbLocal -RepoRoot $repoRoot -Skip ([bool]$SkipMcDbLog)
$mcDbAvailable = [bool]$mcDb.available
$mcDbLogError = [string]$mcDb.error

$startedAt = Get-Date
$signalName = "provider_snapshot_spine_runner_completed"

try {
    $script:Stage = "kill_switch"

    if ($loggingAvailable) {
        $killEnabled = Test-KillSwitchCompatible -Name $KillSwitchName -DefaultEnabled $true

        if (-not $killEnabled) {
            Write-JobLog `
                -RunId $script:RunId `
                -JobName $WorkerName `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -EventType "worker_blocked" `
                -Status "blocked" `
                -Data @{
                    event_message = "Provider snapshot spine runner blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                    mac_user_id = $MacUserId
                    provider_label = $ProviderLabelForChildren
                    mc_db_available = $mcDbAvailable
                    mc_db_error = $mcDbLogError
                } | Out-Null

            Write-Output "BLOCKED: provider snapshot spine runner blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
            exit 0
        }

        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_started" `
            -Status "started" `
            -Data @{
                event_message = "Provider snapshot spine runner started."
                mac_user_id = $MacUserId
                provider_label = $ProviderLabelForChildren
                continue_on_error = [bool]$ContinueOnError
                mc_db_available = $mcDbAvailable
                mc_db_error = $mcDbLogError
            } | Out-Null
    }

    $script:Stage = "run_child_workers"

    $steps = @()

    if (-not $SkipAccountInspection) {
        $steps += [pscustomobject]@{
            name = "inspect_provider_account_context"
            path = "tools\workers\inspect_provider_account_context.ps1"
        }
    }

    $steps += @(
        [pscustomobject]@{ name = "build_provider_live_categories_snapshot";   path = "tools\workers\build_provider_live_categories_snapshot.ps1" },
        [pscustomobject]@{ name = "build_provider_vod_categories_snapshot";    path = "tools\workers\build_provider_vod_categories_snapshot.ps1" },
        [pscustomobject]@{ name = "build_provider_series_categories_snapshot"; path = "tools\workers\build_provider_series_categories_snapshot.ps1" },
        [pscustomobject]@{ name = "build_provider_live_streams_snapshot";      path = "tools\workers\build_provider_live_streams_snapshot.ps1" },
        [pscustomobject]@{ name = "build_provider_vod_streams_snapshot";       path = "tools\workers\build_provider_vod_streams_snapshot.ps1" },
        [pscustomobject]@{ name = "build_provider_series_streams_snapshot";    path = "tools\workers\build_provider_series_streams_snapshot.ps1" },
        [pscustomobject]@{ name = "plan_provider_snapshot_delta";              path = "tools\workers\plan_provider_snapshot_delta.ps1" }
    )

    $rows = @()

    foreach ($step in $steps) {
        $row = Invoke-ChildWorkerLocal `
            -RepoRoot $repoRoot `
            -RelativePath ([string]$step.path) `
            -StepName ([string]$step.name) `
            -Environment $Environment `
            -MacUserId $MacUserId `
            -ProviderLabel $ProviderLabelForChildren

        $rows += $row

        Write-Output ("STEP: {0} status={1} exit_code={2} duration_ms={3}" -f $row.step_name, $row.status, $row.exit_code, $row.duration_ms)

        if ($row.step_name -eq "inspect_provider_account_context" -and $row.exit_code -eq 0) {
            $resolvedProviderLabel = Get-ResolvedProviderLabelFromChildOutputLocal -StdoutTail $row.stdout_tail
            if (-not [string]::IsNullOrWhiteSpace($resolvedProviderLabel)) {
                $ProviderLabelForChildren = $resolvedProviderLabel
                Write-Output ("PROVIDER: resolved_provider_label={0}" -f $ProviderLabelForChildren)
            }
        }

        if ($row.exit_code -ne 0 -and -not $ContinueOnError) {
            break
        }
    }

    $failed = @($rows | Where-Object { $_.status -ne "pass" })
    $statusValue = if ($failed.Count -eq 0 -and $rows.Count -eq $steps.Count) { "pass" } else { "fail" }

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $outputRootFull "provider_snapshot_spine_runner_report_$stamp.csv"
    $summaryJson = Join-Path $outputRootFull "provider_snapshot_spine_runner_summary_$stamp.json"

    $rows | Export-Csv -LiteralPath $reportCsv -NoTypeInformation -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    $summary = [pscustomobject]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        provider_calls = $true
        db_imported = $false
        db_writes = $false
        mac_user_id = $MacUserId
        provider_label = $ProviderLabelForChildren
        step_count = $steps.Count
        executed_count = $rows.Count
        pass_count = @($rows | Where-Object { $_.status -eq "pass" }).Count
        fail_count = $failed.Count
        status = $statusValue
        report_csv = $reportCsv
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    if ($mcDbAvailable -and -not $SkipMcDbLog) {
        $script:Stage = "emit_master_control_db"

        try {
            Write-MasterControlDbForSpineLocal `
                -Summary $summary `
                -Rows $rows `
                -SummaryJson $summaryJson `
                -ReportCsv $reportCsv
        }
        catch {
            $mcDbLogError = "Master Control DB logging failed: $($_.Exception.Message)"

            if ($loggingAvailable) {
                Write-JobLog `
                    -RunId $script:RunId `
                    -JobName $WorkerName `
                    -WorkerName $WorkerName `
                    -Component $Component `
                    -Environment $Environment `
                    -EventType "master_control_db_log_failed" `
                    -Status "warning" `
                    -Data @{
                        event_message = "Provider snapshot spine completed, but Master Control DB logging failed."
                        error = $mcDbLogError
                    } | Out-Null
            }

            Write-Warning $mcDbLogError
        }
    }

    if ($loggingAvailable) {
        $script:Stage = "emit_success"

        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status $statusValue `
            -Data @{
                event_message = "Provider snapshot spine runner completed."
                provider_calls = $true
                db_imported = $false
                step_count = $steps.Count
                executed_count = $rows.Count
                pass_count = $summary.pass_count
                fail_count = $summary.fail_count
                duration_ms = $durationMs
                mc_db_available = $mcDbAvailable
                mc_db_error = $mcDbLogError
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue $statusValue `
            -Status $statusValue `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/run_provider_snapshot_spine.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.snapshot.spine.runner"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                provider_calls = $true
                db_imported = $false
                mc_db_available = $mcDbAvailable
                mc_db_error = $mcDbLogError
                report_csv = $reportCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("RESULT: {0} step_count={1} executed_count={2} pass_count={3} fail_count={4} provider_calls=True db_imported=False mc_db_available={5} run_id={6}" -f `
        $statusValue, `
        $steps.Count, `
        $rows.Count, `
        $summary.pass_count, `
        $summary.fail_count, `
        $mcDbAvailable, `
        $script:RunId)

    Write-Output ("FILES: report_csv=""{0}"" summary_json=""{1}""" -f $reportCsv, $summaryJson)

    $rows | Select-Object step_name, status, exit_code, duration_ms | Format-Table -AutoSize

    if ($statusValue -ne "pass") {
        exit 1
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
            -Status "failed" `
            -Data @{
                event_message = "Provider snapshot spine runner failed."
                error = $errorMessage
                mc_db_available = $mcDbAvailable
                mc_db_error = $mcDbLogError
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue "fail" `
            -Status "fail" `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/run_provider_snapshot_spine.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.snapshot.spine.runner"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
                mc_db_available = $mcDbAvailable
                mc_db_error = $mcDbLogError
            } | Out-Null
    }

    Write-Error "FAILED: provider snapshot spine runner failed. run_id=$script:RunId $errorMessage"
    exit 1
}
