# MiraTV Ingest Automation Logging Helper
# File: tools/common/Logging.psm1
# Purpose:
#   Shared local-first logging, heartbeat, signal, kill-switch, and redaction helpers
#   for MiraTV ingest/batch/worker automation.
#
# Contract:
#   - No external dependencies.
#   - Safe local JSONL fallback by default.
#   - No DB dependency in this first helper version.
#   - Never log raw provider usernames, passwords, tokens, API keys, or playback URLs.
#   - Designed to satisfy the Automation Implementation Contract baseline.

Set-StrictMode -Version Latest

function New-RunId {
    [CmdletBinding()]
    param(
        [string]$Prefix = "run"
    )

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N")
    return "$Prefix-$stamp-$guid"
}

function Get-MiraTvRepoRoot {
    [CmdletBinding()]
    param()

    $modulePath = $PSScriptRoot

    if ([string]::IsNullOrWhiteSpace($modulePath)) {
        return (Get-Location).Path
    }

    # Expected module location:
    #   <repo>\tools\common\Logging.psm1
    # So repo root is two levels up from tools\common.
    $root = Resolve-Path -Path (Join-Path $modulePath "..\..") -ErrorAction SilentlyContinue

    if ($null -ne $root) {
        return $root.Path
    }

    return (Get-Location).Path
}

function New-DirectoryIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function ConvertTo-JsonSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    return ($InputObject | ConvertTo-Json -Depth 20 -Compress)
}

function Redact-Secret {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [string]$FieldName = ""
    )

    if ($null -eq $Value) {
        return $null
    }

    $sensitiveNamePattern = '(?i)(provider_username|provider_password|password|passwd|pwd|token|api_key|apikey|secret|credential|auth|authorization|full_playback_url|playback_url|provider_url|url)'

    if ($FieldName -match $sensitiveNamePattern) {
        if ($FieldName -match '(?i)(full_playback_url|playback_url|provider_url|url)') {
            return "REDACTED_URL"
        }

        return "REDACTED"
    }

    if ($Value -is [string]) {
        $text = [string]$Value

        # Redact obvious credential fragments inside text values.
        $text = $text -replace '(?i)(password|passwd|pwd|token|api_key|apikey|secret|username|user)=([^&\s]+)', '$1=REDACTED'
        $text = $text -replace '(?i)(Bearer\s+)[A-Za-z0-9\-\._~\+\/]+=*', '$1REDACTED'
        $text = $text -replace '(?i)(http|https)://[^ \t\r\n"]+', 'REDACTED_URL'

        return $text
    }

    return $Value
}

function Protect-LogData {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [hashtable]$Data
    )

    $clean = [ordered]@{}

    if ($null -eq $Data) {
        return $clean
    }

    foreach ($key in $Data.Keys) {
        $value = $Data[$key]

        if ($value -is [hashtable]) {
            $clean[$key] = Protect-LogData -Data $value
        }
        elseif ($value -is [System.Collections.IDictionary]) {
            $nested = @{}
            foreach ($nestedKey in $value.Keys) {
                $nested[$nestedKey] = Redact-Secret -FieldName ([string]$nestedKey) -Value $value[$nestedKey]
            }
            $clean[$key] = $nested
        }
        else {
            $clean[$key] = Redact-Secret -FieldName ([string]$key) -Value $value
        }
    }

    return $clean
}

function Get-DefaultLogRoot {
    [CmdletBinding()]
    param()

    $repoRoot = Get-MiraTvRepoRoot
    return (Join-Path $repoRoot "runtime\logs")
}

function Write-JsonLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Record,

        [string]$LogRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($LogRoot)) {
        $LogRoot = Get-DefaultLogRoot
    }

    $component = "unknown_component"

    if ($Record.ContainsKey("component") -and -not [string]::IsNullOrWhiteSpace([string]$Record["component"])) {
        $component = [string]$Record["component"]
    }

    $safeComponent = $component -replace '[^A-Za-z0-9_\-\.]', '_'
    $componentDir = Join-Path $LogRoot $safeComponent
    New-DirectoryIfMissing -Path $componentDir

    $datePart = (Get-Date).ToUniversalTime().ToString("yyyyMMdd")
    $logFile = Join-Path $componentDir "$datePart.jsonl"

    $json = ConvertTo-JsonSafe -InputObject $Record
    Add-Content -LiteralPath $logFile -Value $json -Encoding UTF8

    return $logFile
}

function New-BaseLogRecord {
    [CmdletBinding()]
    param(
        [string]$RunId = "",
        [string]$JobName = "",
        [string]$WorkerName = "",
        [string]$Component = "",
        [string]$Environment = "prod",
        [string]$Status = "info",
        [string]$EventType = "job_event",
        [hashtable]$Data = $null
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = New-RunId
    }

    if ([string]::IsNullOrWhiteSpace($JobName)) {
        $JobName = "unknown_job"
    }

    if ([string]::IsNullOrWhiteSpace($WorkerName)) {
        $WorkerName = "unknown_worker"
    }

    if ([string]::IsNullOrWhiteSpace($Component)) {
        $Component = "unknown_component"
    }

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        $Environment = "prod"
    }

    if ([string]::IsNullOrWhiteSpace($Status)) {
        $Status = "info"
    }

    if ([string]::IsNullOrWhiteSpace($EventType)) {
        $EventType = "job_event"
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")

    $record = [ordered]@{
        timestamp    = $now
        emitted_at   = $now
        run_id       = $RunId
        job_name     = $JobName
        worker_name  = $WorkerName
        component    = $Component
        environment  = $Environment
        status       = $Status
        event_type   = $EventType
    }

    if ($null -ne $Data) {
        $cleanData = Protect-LogData -Data $Data
        foreach ($key in $cleanData.Keys) {
            $record[$key] = $cleanData[$key]
        }
    }

    return $record
}

function Test-KillSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [bool]$DefaultEnabled = $true
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Kill switch name is required."
    }

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "User")
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "Machine")
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultEnabled
    }

    $normalized = $value.Trim().ToLowerInvariant()

    if ($normalized -in @("1", "true", "yes", "y", "on", "enabled", "enable")) {
        return $true
    }

    if ($normalized -in @("0", "false", "no", "n", "off", "disabled", "disable")) {
        return $false
    }

    return $DefaultEnabled
}

function Write-JobLog {
    [CmdletBinding()]
    param(
        [string]$RunId = "",
        [string]$JobName = "",
        [string]$WorkerName = "",
        [string]$Component = "",
        [string]$Environment = "prod",

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [string]$EventType = "job_event",
        [string]$DatabaseTarget = "",
        [string]$SourceName = "",
        [int]$Attempt = 1,
        [string]$ErrorCode = "",
        [string]$ErrorMessage = "",
        [Nullable[int]]$RowsInserted = $null,
        [Nullable[int]]$RowsUpdated = $null,
        [Nullable[int]]$RowsSkipped = $null,
        [Nullable[int]]$RowsFailed = $null,
        [Nullable[int]]$SourceRowCount = $null,
        [Nullable[int]]$DurationMs = $null,
        [hashtable]$Data = $null,
        [string]$LogRoot = ""
    )

    $payload = @{}

    if (-not [string]::IsNullOrWhiteSpace($DatabaseTarget)) { $payload["database_target"] = $DatabaseTarget }
    if (-not [string]::IsNullOrWhiteSpace($SourceName)) { $payload["source_name"] = $SourceName }

    $payload["attempt"] = $Attempt

    if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $payload["error_code"] = $ErrorCode }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) { $payload["error_message"] = $ErrorMessage }

    if ($null -ne $RowsInserted) { $payload["rows_inserted"] = $RowsInserted }
    if ($null -ne $RowsUpdated) { $payload["rows_updated"] = $RowsUpdated }
    if ($null -ne $RowsSkipped) { $payload["rows_skipped"] = $RowsSkipped }
    if ($null -ne $RowsFailed) { $payload["rows_failed"] = $RowsFailed }
    if ($null -ne $SourceRowCount) { $payload["source_row_count"] = $SourceRowCount }
    if ($null -ne $DurationMs) { $payload["duration_ms"] = $DurationMs }

    if ($null -ne $Data) {
        foreach ($key in $Data.Keys) {
            $payload[$key] = $Data[$key]
        }
    }

    $record = New-BaseLogRecord `
        -RunId $RunId `
        -JobName $JobName `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status $Status `
        -EventType $EventType `
        -Data $payload

    return Write-JsonLine -Record $record -LogRoot $LogRoot
}

function Emit-Heartbeat {
    [CmdletBinding()]
    param(
        [string]$RunId = "",
        [string]$JobName = "worker_heartbeat",
        [string]$WorkerName = "",
        [string]$Component = "",
        [string]$Environment = "prod",
        [string]$HeartbeatStatus = "ok",
        [int]$HeartbeatIntervalSeconds = 60,
        [int]$StaleAfterSeconds = 300,
        [hashtable]$Data = $null,
        [string]$LogRoot = ""
    )

    $payload = @{
        heartbeat_status           = $HeartbeatStatus
        heartbeat_interval_seconds = $HeartbeatIntervalSeconds
        stale_after_seconds        = $StaleAfterSeconds
        last_heartbeat_at          = (Get-Date).ToUniversalTime().ToString("o")
    }

    if ($null -ne $Data) {
        foreach ($key in $Data.Keys) {
            $payload[$key] = $Data[$key]
        }
    }

    $record = New-BaseLogRecord `
        -RunId $RunId `
        -JobName $JobName `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status $HeartbeatStatus `
        -EventType "heartbeat" `
        -Data $payload

    return Write-JsonLine -Record $record -LogRoot $LogRoot
}

function Emit-Signal {
    [CmdletBinding()]
    param(
        [string]$RunId = "",
        [string]$JobName = "emit_signal",
        [string]$WorkerName = "",
        [string]$Component = "",
        [string]$Environment = "prod",

        [Parameter(Mandatory = $true)]
        [string]$SignalName,

        [string]$P0Item = "",
        [string]$SignalValue = "",
        [Nullable[decimal]]$ValueNum = $null,
        [string]$Status = "ok",
        [string]$AllowedValues = "",
        [string]$SourceTableOrEndpoint = "",
        [string]$MacUserId = "",
        [string]$ScreenType = "",
        [string]$ErrorCode = "",
        [string]$ErrorMessage = "",
        [hashtable]$Data = $null,
        [string]$LogRoot = ""
    )

    $payload = @{
        signal_name = $SignalName
    }

    if (-not [string]::IsNullOrWhiteSpace($P0Item)) { $payload["p0_item"] = $P0Item }
    if (-not [string]::IsNullOrWhiteSpace($SignalValue)) { $payload["signal_value"] = $SignalValue }
    if ($null -ne $ValueNum) { $payload["value_num"] = $ValueNum }
    if (-not [string]::IsNullOrWhiteSpace($AllowedValues)) { $payload["allowed_values"] = $AllowedValues }
    if (-not [string]::IsNullOrWhiteSpace($SourceTableOrEndpoint)) { $payload["source_table_or_endpoint"] = $SourceTableOrEndpoint }
    if (-not [string]::IsNullOrWhiteSpace($MacUserId)) { $payload["mac_user_id"] = $MacUserId }
    if (-not [string]::IsNullOrWhiteSpace($ScreenType)) { $payload["screen_type"] = $ScreenType }
    if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $payload["error_code"] = $ErrorCode }
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) { $payload["error_message"] = $ErrorMessage }

    if ($null -ne $Data) {
        foreach ($key in $Data.Keys) {
            $payload[$key] = $Data[$key]
        }
    }

    $record = New-BaseLogRecord `
        -RunId $RunId `
        -JobName $JobName `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status $Status `
        -EventType "signal" `
        -Data $payload

    return Write-JsonLine -Record $record -LogRoot $LogRoot
}

Export-ModuleMember -Function `
    New-RunId, `
    Redact-Secret, `
    Test-KillSwitch, `
    Write-JobLog, `
    Emit-Heartbeat, `
    Emit-Signal