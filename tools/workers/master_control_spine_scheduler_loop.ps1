<#
.SYNOPSIS
  DB-backed Master Control scheduler loop for provider snapshot spine.

.DESCRIPTION
  Preferred control source:
    xpdgxfsp_content.mc_scheduler_control
    scheduler_name = provider_snapshot_spine

  Fallback control source:
    runtime\control\spine_scheduler_control.json

  State file:
    runtime\control\spine_scheduler_state.json

  Flow:
    scheduler -> run_provider_snapshot_spine.ps1 -> direct MC DB logging
              -> get_master_control_dashboard_cards.ps1 -> state update

  No Windows Task Scheduler required.

.PARAMETER Once
  Evaluate once and exit.

.PARAMETER ForceRun
  Run immediately regardless of next_run_at/run_now.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\miraTV_ingest_clean",
    [string]$SchedulerName = "provider_snapshot_spine",
    [int]$PollSeconds = 30,
    [switch]$Once,
    [switch]$ForceRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Set-Location $RepoRoot

$WorkerName = "master_control_spine_scheduler_loop"
$ControlRoot = Join-Path $RepoRoot "runtime\control"
$LogRoot = Join-Path $RepoRoot "runtime\logs\master_control_spine_scheduler_loop"
$ReportRoot = Join-Path $RepoRoot "runtime\reports\master_control_spine_scheduler_loop"
$LockRoot = Join-Path $RepoRoot "runtime\locks"

$ControlFile = Join-Path $ControlRoot "spine_scheduler_control.json"
$StateFile = Join-Path $ControlRoot "spine_scheduler_state.json"
$LockFile = Join-Path $LockRoot "provider_snapshot_spine.lock"

New-Item -ItemType Directory -Force -Path $ControlRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LockRoot | Out-Null

function Write-LoopLog {
    param([string]$Status, [string]$Message, [object]$Data = $null)

    $record = [ordered]@{
        event_ts = (Get-Date).ToUniversalTime().ToString("o")
        worker_name = $WorkerName
        scheduler_name = $SchedulerName
        status = $Status
        message = $Message
        data = $Data
    }

    $logFile = Join-Path $LogRoot "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).jsonl"
    Add-Content -LiteralPath $logFile -Value ($record | ConvertTo-Json -Depth 20 -Compress)
    Write-Host ("{0} [{1}] {2}" -f $record.event_ts, $Status, $Message)
}

function ConvertTo-SqlLiteralLocal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "NULL" }

    if ($Value -is [bool]) {
        if ($Value) { return "1" }
        return "0"
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
        return ([string]$Value)
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return "NULL" }

    $text = $text.Replace("\", "\\")
    $text = $text.Replace("'", "''")
    return "'" + $text + "'"
}

function New-DefaultControl {
    return [ordered]@{
        enabled = $true
        environment = "dev"
        mac_user_id = 6
        interval_minutes = 60
        run_now = $false
        stop_after_current = $false
        quiet = $false
        control_source = "default"
    }
}

function Write-ControlJson {
    param([object]$Control)
    $Control | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ControlFile -Encoding UTF8
}

function Read-ControlJson {
    if (-not (Test-Path -LiteralPath $ControlFile)) {
        Write-ControlJson -Control (New-DefaultControl)
    }

    try {
        $control = Get-Content -LiteralPath $ControlFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-LoopLog -Status "warning" -Message "Control file parse failed. Rewriting default control file." -Data $_.Exception.Message
        Write-ControlJson -Control (New-DefaultControl)
        $control = Get-Content -LiteralPath $ControlFile -Raw | ConvertFrom-Json
    }

    if (-not ($control.PSObject.Properties.Name -contains "control_source")) {
        $control | Add-Member -NotePropertyName "control_source" -NotePropertyValue "json"
    } else {
        $control.control_source = "json"
    }

    return $control
}

function New-DefaultState {
    return [ordered]@{
        last_run_at_utc = $null
        next_run_at_utc = $null
        last_status = "never_run"
        last_disposition = ""
        last_exit_code = $null
        last_spine_log_file = ""
        last_dashboard_log_file = ""
        current_run_started_at_utc = $null
        is_running = $false
        updated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Write-State {
    param([object]$State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        New-DefaultState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StateFile -Encoding UTF8
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    }
    catch {
        New-DefaultState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StateFile -Encoding UTF8
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    }

    $default = New-DefaultState
    $changed = $false

    foreach ($key in $default.Keys) {
        if (-not ($state.PSObject.Properties.Name -contains $key)) {
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $default[$key]
            $changed = $true
        }
    }

    if (($state.PSObject.Properties.Name -contains "last_log_file") -and
        ($state.PSObject.Properties.Name -contains "last_spine_log_file") -and
        [string]::IsNullOrWhiteSpace([string]$state.last_spine_log_file) -and
        -not [string]::IsNullOrWhiteSpace([string]$state.last_log_file)) {
        $state.last_spine_log_file = $state.last_log_file
        $changed = $true
    }

    if ($changed) {
        $state.updated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        Write-State -State $state
    }

    return $state
}

function Initialize-DbQueryLocal {
    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    if (-not (Test-Path -LiteralPath $modulePath)) {
        return [pscustomobject]@{ available = $false; error = "DbQuery module not found: $modulePath" }
    }

    try {
        Import-Module $modulePath -Force
        [void](Resolve-DogOpenProcEndpoint -DatabaseKey "content")
        return [pscustomobject]@{
            available = [bool](Get-Command Invoke-DogOpenProc -ErrorAction SilentlyContinue)
            error = ""
        }
    }
    catch {
        return [pscustomobject]@{ available = $false; error = $_.Exception.Message }
    }
}

function Convert-DbBool {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    return ([int]$Value -ne 0)
}

function Read-ControlDb {
    param([bool]$DbAvailable)

    if (-not $DbAvailable) { return $null }

    try {
        $schedulerSql = ConvertTo-SqlLiteralLocal -Value $SchedulerName
        $sql = @"
SELECT
  scheduler_name,
  enabled,
  environment,
  mac_user_id,
  interval_minutes,
  run_now,
  stop_after_current,
  quiet,
  last_run_at_utc,
  next_run_at_utc,
  last_status,
  last_disposition,
  last_exit_code,
  last_spine_log_file,
  last_dashboard_log_file
FROM xpdgxfsp_content.mc_scheduler_control
WHERE scheduler_name = $schedulerSql
LIMIT 1;
"@

        $result = Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120
        $rows = @($result.rows)

        if ($rows.Count -lt 1) { return $null }

        $row = $rows[0]

        return [pscustomobject]@{
            enabled = Convert-DbBool $row.enabled
            environment = [string]$row.environment
            mac_user_id = [int]$row.mac_user_id
            interval_minutes = [int]$row.interval_minutes
            run_now = Convert-DbBool $row.run_now
            stop_after_current = Convert-DbBool $row.stop_after_current
            quiet = Convert-DbBool $row.quiet
            control_source = "db"
            db_next_run_at_utc = [string]$row.next_run_at_utc
            db_last_status = [string]$row.last_status
            db_last_disposition = [string]$row.last_disposition
        }
    }
    catch {
        Write-LoopLog -Status "warning" -Message "DB control read failed; falling back to JSON control." -Data $_.Exception.Message
        return $null
    }
}

function Clear-DbRunNow {
    param([bool]$DbAvailable)

    if (-not $DbAvailable) { return }

    try {
        $schedulerSql = ConvertTo-SqlLiteralLocal -Value $SchedulerName
        $sql = "UPDATE xpdgxfsp_content.mc_scheduler_control SET run_now = 0 WHERE scheduler_name = $schedulerSql;"
        Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120 | Out-Null
    }
    catch {
        Write-LoopLog -Status "warning" -Message "Failed to clear DB run_now flag." -Data $_.Exception.Message
    }
}

function Update-DbSchedulerState {
    param([bool]$DbAvailable, [object]$Result, [datetime]$NextRunAt)

    if (-not $DbAvailable) { return }

    try {
        $schedulerSql = ConvertTo-SqlLiteralLocal -Value $SchedulerName
        $lastRunSql = ConvertTo-SqlLiteralLocal -Value ((Get-Date).ToUniversalTime().ToString("o"))
        $nextRunSql = ConvertTo-SqlLiteralLocal -Value ($NextRunAt.ToString("o"))
        $statusSql = ConvertTo-SqlLiteralLocal -Value $Result.status
        $dispositionSql = ConvertTo-SqlLiteralLocal -Value $Result.disposition
        $exitSql = ConvertTo-SqlLiteralLocal -Value $Result.exit_code
        $spineLogSql = ConvertTo-SqlLiteralLocal -Value $Result.spine_log_file
        $dashboardLogSql = ConvertTo-SqlLiteralLocal -Value $Result.dashboard_log_file

        $sql = @"
UPDATE xpdgxfsp_content.mc_scheduler_control
SET
  run_now = 0,
  last_run_at_utc = $lastRunSql,
  next_run_at_utc = $nextRunSql,
  last_status = $statusSql,
  last_disposition = $dispositionSql,
  last_exit_code = $exitSql,
  last_spine_log_file = $spineLogSql,
  last_dashboard_log_file = $dashboardLogSql
WHERE scheduler_name = $schedulerSql;
"@
        Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120 | Out-Null
    }
    catch {
        Write-LoopLog -Status "warning" -Message "Failed to update DB scheduler state." -Data $_.Exception.Message
    }
}

function Test-LockActive {
    if (-not (Test-Path -LiteralPath $LockFile)) { return $false }

    try {
        $lock = Get-Content -LiteralPath $LockFile -Raw | ConvertFrom-Json
        if ($lock.expires_at_utc) {
            $expires = [datetime]::Parse([string]$lock.expires_at_utc).ToUniversalTime()
            if ($expires -lt (Get-Date).ToUniversalTime()) {
                Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
                return $false
            }
        }
    }
    catch {
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    return $true
}

function Acquire-Lock {
    param([string]$RunId, [int]$Minutes = 180)

    if (Test-LockActive) { return $false }

    [ordered]@{
        lock_name = "provider_snapshot_spine"
        run_id = $RunId
        worker_name = $WorkerName
        acquired_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        expires_at_utc = (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString("o")
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LockFile -Encoding UTF8

    return $true
}

function Release-Lock {
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}

function Invoke-LoggedWorker {
    param([string]$WorkerPath, [string[]]$Arguments, [string]$LogPrefix)

    if (-not (Test-Path -LiteralPath $WorkerPath)) {
        throw "Worker not found: $WorkerPath"
    }

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $stdoutLog = Join-Path $ReportRoot "$LogPrefix`_$stamp.log"
    $stderrLog = Join-Path $ReportRoot "$LogPrefix`_$stamp.err.log"

    $argumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $WorkerPath) + $Arguments

    $process = Start-Process `
        -FilePath "pwsh.exe" `
        -ArgumentList $argumentList `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog

    return [pscustomobject]@{
        worker_path = $WorkerPath
        exit_code = [int]$process.ExitCode
        stdout_log = $stdoutLog
        stderr_log = $stderrLog
    }
}

function Invoke-SpineAndDashboardRun {
    param([string]$Environment, [int]$MacUserId, [bool]$Quiet)

    $runId = "scheduled-spine-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 12))"

    if (-not (Acquire-Lock -RunId $runId -Minutes 180)) {
        Write-LoopLog -Status "warning" -Message "Spine lock active; skipping scheduled run." -Data @{ run_id = $runId }
        return [pscustomobject]@{
            run_id = $runId
            status = "skipped"
            disposition = "lock_active"
            exit_code = $null
            spine_log_file = ""
            dashboard_log_file = ""
            actual_run = $false
        }
    }

    $state = Read-State
    $state.is_running = $true
    $state.current_run_started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    $state.updated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-State -State $state

    try {
        Write-LoopLog -Status "start" -Message "Starting scheduled spine + dashboard refresh." -Data @{
            run_id = $runId
            environment = $Environment
            mac_user_id = $MacUserId
        }

        $spineWorker = Join-Path $RepoRoot "tools\workers\run_provider_snapshot_spine.ps1"
        $spine = Invoke-LoggedWorker `
            -WorkerPath $spineWorker `
            -Arguments @("-Environment", $Environment, "-MacUserId", ([string]$MacUserId)) `
            -LogPrefix "scheduled_provider_snapshot_spine"

        if ($spine.exit_code -ne 0) {
            Write-LoopLog -Status "fail" -Message "Scheduled spine failed." -Data @{
                run_id = $runId
                exit_code = $spine.exit_code
                stdout_log = $spine.stdout_log
                stderr_log = $spine.stderr_log
            }

            return [pscustomobject]@{
                run_id = $runId
                status = "fail"
                disposition = "spine_failed"
                exit_code = $spine.exit_code
                spine_log_file = $spine.stdout_log
                dashboard_log_file = ""
                actual_run = $true
            }
        }

        $dashboardWorker = Join-Path $RepoRoot "tools\workers\get_master_control_dashboard_cards.ps1"
        $dashboardArgs = @("-Environment", $Environment)
        if ($Quiet) { $dashboardArgs += "-Quiet" }

        $dashboard = Invoke-LoggedWorker `
            -WorkerPath $dashboardWorker `
            -Arguments $dashboardArgs `
            -LogPrefix "scheduled_master_control_dashboard_cards"

        if ($dashboard.exit_code -ne 0) {
            Write-LoopLog -Status "warning" -Message "Dashboard refresh failed after successful spine." -Data @{
                run_id = $runId
                exit_code = $dashboard.exit_code
                stdout_log = $dashboard.stdout_log
                stderr_log = $dashboard.stderr_log
            }

            return [pscustomobject]@{
                run_id = $runId
                status = "warning"
                disposition = "spine_pass_dashboard_failed"
                exit_code = $dashboard.exit_code
                spine_log_file = $spine.stdout_log
                dashboard_log_file = $dashboard.stdout_log
                actual_run = $true
            }
        }

        Write-LoopLog -Status "pass" -Message "Scheduled spine + dashboard refresh completed." -Data @{
            run_id = $runId
            spine_log = $spine.stdout_log
            dashboard_log = $dashboard.stdout_log
        }

        return [pscustomobject]@{
            run_id = $runId
            status = "pass"
            disposition = "spine_pass_dashboard_refreshed"
            exit_code = 0
            spine_log_file = $spine.stdout_log
            dashboard_log_file = $dashboard.stdout_log
            actual_run = $true
        }
    }
    finally {
        Release-Lock

        $state = Read-State
        $state.is_running = $false
        $state.current_run_started_at_utc = $null
        $state.updated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        Write-State -State $state
    }
}

$dbInit = Initialize-DbQueryLocal
$dbAvailable = [bool]$dbInit.available

Write-LoopLog -Status "start" -Message "Master Control spine scheduler loop started." -Data @{
    repo_root = $RepoRoot
    scheduler_name = $SchedulerName
    control_file = $ControlFile
    state_file = $StateFile
    poll_seconds = $PollSeconds
    once = [bool]$Once
    force_run = [bool]$ForceRun
    db_control_available = $dbAvailable
    db_control_error = $dbInit.error
}

while ($true) {
    $dbControl = Read-ControlDb -DbAvailable $dbAvailable
    $control = if ($null -ne $dbControl) { $dbControl } else { Read-ControlJson }
    $state = Read-State
    $now = (Get-Date).ToUniversalTime()

    $enabled = [bool]$control.enabled
    $runNow = [bool]$control.run_now
    $stopAfterCurrent = [bool]$control.stop_after_current
    $environment = [string]$control.environment
    $macUserId = [int]$control.mac_user_id
    $intervalMinutes = [int]$control.interval_minutes
    $quiet = if ($control.PSObject.Properties.Name -contains "quiet") { [bool]$control.quiet } else { $false }

    if ($intervalMinutes -lt 1) { $intervalMinutes = 60 }

    if ($stopAfterCurrent -and -not $state.is_running) {
        Write-LoopLog -Status "stop" -Message "stop_after_current requested; exiting scheduler loop."
        break
    }

    $nextRunAt = $null

    if ($control.PSObject.Properties.Name -contains "db_next_run_at_utc" -and
        -not [string]::IsNullOrWhiteSpace([string]$control.db_next_run_at_utc)) {
        try { $nextRunAt = [datetime]::Parse([string]$control.db_next_run_at_utc).ToUniversalTime() } catch { $nextRunAt = $null }
    }

    if ($null -eq $nextRunAt -and $state.next_run_at_utc) {
        try { $nextRunAt = [datetime]::Parse([string]$state.next_run_at_utc).ToUniversalTime() } catch { $nextRunAt = $null }
    }

    if ($null -eq $nextRunAt) { $nextRunAt = $now }

    $shouldRun = $enabled -and ($ForceRun -or $runNow -or ($now -ge $nextRunAt))

    if ($shouldRun) {
        if ($runNow) {
            if ($control.control_source -eq "db") {
                Clear-DbRunNow -DbAvailable $dbAvailable
            } else {
                $control.run_now = $false
                Write-ControlJson -Control $control
            }
        }

        $result = Invoke-SpineAndDashboardRun -Environment $environment -MacUserId $macUserId -Quiet $quiet
        $next = (Get-Date).ToUniversalTime().AddMinutes($intervalMinutes)

        $state = Read-State
        $state.last_run_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        $state.next_run_at_utc = $next.ToString("o")
        $state.last_status = $result.status
        $state.last_disposition = $result.disposition
        $state.last_exit_code = $result.exit_code
        $state.last_spine_log_file = $result.spine_log_file
        $state.last_dashboard_log_file = $result.dashboard_log_file
        $state.updated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        Write-State -State $state

        Update-DbSchedulerState -DbAvailable $dbAvailable -Result $result -NextRunAt $next

        if ($stopAfterCurrent -or $Once) {
            Write-LoopLog -Status "stop" -Message "Exiting scheduler loop after run." -Data @{
                stop_after_current = $stopAfterCurrent
                once = [bool]$Once
                control_source = [string]$control.control_source
            }
            break
        }
    } else {
        if (-not $enabled) {
            Write-LoopLog -Status "idle" -Message "Scheduler disabled. Waiting." -Data @{
                poll_seconds = $PollSeconds
                control_source = [string]$control.control_source
            }
        }
        elseif ($Once) {
            Write-LoopLog -Status "idle" -Message "No run due during -Once evaluation. Exiting." -Data @{
                control_source = [string]$control.control_source
                next_run_at_utc = $nextRunAt.ToString("o")
            }
            break
        }
    }

    Start-Sleep -Seconds $PollSeconds
}
