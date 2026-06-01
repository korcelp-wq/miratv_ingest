[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [string]$PreviewCsvPath = "",
    [int]$Limit = 25,
    [switch]$Apply,
    [switch]$AllowDbWrite,
    [string]$WriteAuthorizationCode = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "apply_epg_programs_delta_limited"
$Component = "epg_programs_delta_limited_apply"
$DatabaseKey = "content"
$WriteKillSwitchName = "ENABLE_EPG_PROGRAMS_DELTA_LIMITED_APPLY_WRITES"
$ExpectedWriteAuthorizationCode = "APPLY_EPG_PROGRAMS_DELTA_LIMITED"

$RepoRoot = (Resolve-Path ".").Path
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$OutDir = Join-Path $RepoRoot "runtime\reports\epg_programs_delta_limited_apply"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_programs_delta_limited_apply"

New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $LogDir | Out-Null

$ApplyCsvPath = Join-Path $OutDir "epg_programs_delta_limited_apply_$Stamp.csv"
$SummaryPath = Join-Path $OutDir "epg_programs_delta_limited_apply_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Write-Event {
    param([hashtable]$Event)

    $Event.run_id = $RunId
    $Event.worker_name = $WorkerName
    $Event.component = $Component
    $Event.environment = $Environment
    $Event.provider = $Provider
    $Event.timestamp = (Get-Date).ToUniversalTime().ToString("o")

    ($Event | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

function Get-LatestPreviewCsv {
    $folder = Join-Path $RepoRoot "runtime\reports\epg_programs_delta_preview"
    if (-not (Test-Path $folder)) {
        throw "Preview folder not found: $folder"
    }

    $latest = Get-ChildItem $folder -File |
        Where-Object { $_.Name -match "^epg_programs_delta_preview_\d{8}T\d{6}Z\.csv$" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        throw "No EPG preview CSV found."
    }

    return $latest.FullName
}

function Get-WriteAuthorization {
    $rawSwitch = [Environment]::GetEnvironmentVariable($WriteKillSwitchName)
    $switchEnabled = $false

    if (-not [string]::IsNullOrWhiteSpace($rawSwitch)) {
        $switchEnabled = ($rawSwitch.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on", "enabled"))
    }

    $codeMatches = (-not [string]::IsNullOrWhiteSpace($WriteAuthorizationCode) -and $WriteAuthorizationCode -eq $ExpectedWriteAuthorizationCode)

    $reasons = @()
    if (-not [bool]$Apply) { $reasons += "apply_switch_not_passed" }
    if (-not [bool]$AllowDbWrite) { $reasons += "allow_db_write_not_passed" }
    if (-not $switchEnabled) { $reasons += "write_kill_switch_not_enabled" }
    if (-not $codeMatches) { $reasons += "write_authorization_code_invalid_or_missing" }

    return [pscustomobject][ordered]@{
        authorized = ([bool]$Apply -and [bool]$AllowDbWrite -and $switchEnabled -and $codeMatches)
        write_kill_switch_name = $WriteKillSwitchName
        write_kill_switch_enabled = $switchEnabled
        write_authorization_code_present = (-not [string]::IsNullOrWhiteSpace($WriteAuthorizationCode))
        write_authorization_code_matches = $codeMatches
        required_authorization_code = $ExpectedWriteAuthorizationCode
        block_reasons = $reasons
    }
}

function Escape-Sql {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    $text = [string]$Value

    if ([string]::IsNullOrWhiteSpace($text)) {
        return "NULL"
    }

    $escaped = $text.Replace("\", "\\").Replace("'", "''")
    return "'$escaped'"
}

function Escape-Sql-Required {
    param([AllowNull()][object]$Value)

    $text = [string]$Value
    $escaped = $text.Replace("\", "\\").Replace("'", "''")
    return "'$escaped'"
}

function Get-IntText {
    param([AllowNull()][object]$Value, [int]$Default = 0)

    $text = [string]$Value
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) {
        return [string]$parsed
    }

    return [string]$Default
}

function New-StableBigIntId {
    param(
        [string]$EpgChannelId,
        [string]$StartTime,
        [string]$EndTime,
        [string]$Title
    )

    $key = "$EpgChannelId|$StartTime|$EndTime|$Title"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)

    $hex = -join ($hash[0..6] | ForEach-Object { $_.ToString("x2") })
    $value = [Convert]::ToInt64($hex, 16)

    if ($value -lt 1) {
        $value = 1
    }

    return $value
}

function Invoke-ApplySql {
    param([string]$Sql)

    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    if (-not (Test-Path $modulePath)) {
        throw "DbQuery module not found: $modulePath"
    }

    Import-Module $modulePath -Force

    return Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $Sql -TimeoutSec 60
}

if ([string]::IsNullOrWhiteSpace($PreviewCsvPath)) {
    $PreviewCsvPath = Get-LatestPreviewCsv
}

if ($Limit -lt 1) { $Limit = 1 }
if ($Limit -gt 1000) { $Limit = 1000 }

$authorization = Get-WriteAuthorization
$dryRun = -not [bool]$authorization.authorized

Write-Event @{
    event_type = "job_started"
    status = "started"
    source_name = $PreviewCsvPath
    dry_run = $dryRun
    db_writes = [bool]$authorization.authorized
    provider_calls = $false
    write_authorization = $authorization
}

$rows = @(Import-Csv -LiteralPath $PreviewCsvPath)
$rows = @(
    $rows |
    Where-Object {
        $_.preview_disposition -eq "preview_ready" -and
        $_.apply_action -eq "upsert_epg_program"
    } |
    Select-Object -First $Limit
)

$results = New-Object System.Collections.Generic.List[object]

$seen = 0
$wouldWrite = 0
$applied = 0
$failed = 0
$skipped = 0
$maxEndTime = ""

foreach ($row in $rows) {
    $seen++

    try {
        $epgChannelId = [string]$row.epg_channel_id
        $startTime = [string]$row.start_time
        $endTime = [string]$row.end_time
        $title = [string]$row.title

        if ([string]::IsNullOrWhiteSpace($epgChannelId) -or
            [string]::IsNullOrWhiteSpace($startTime) -or
            [string]::IsNullOrWhiteSpace($endTime) -or
            [string]::IsNullOrWhiteSpace($title)) {
            $skipped++

            $results.Add([pscustomobject][ordered]@{
                apply_disposition = "skipped_missing_required_fields"
                rows_affected = 0
                dry_run = $dryRun
                epg_channel_id = $epgChannelId
                start_time = $startTime
                end_time = $endTime
                title = $title
                error_message = ""
            })
            continue
        }

        $wouldWrite++

        $stableId = New-StableBigIntId `
            -EpgChannelId $epgChannelId `
            -StartTime $startTime `
            -EndTime $endTime `
            -Title $title

        $provider = if ([string]::IsNullOrWhiteSpace([string]$row.provider)) { $Provider } else { [string]$row.provider }
        $channel = if ([string]::IsNullOrWhiteSpace([string]$row.channel)) { $epgChannelId } else { [string]$row.channel }
        $description = [string]$row.description
        $catchup = Get-IntText -Value $row.catchup -Default 0
        $providerChannelId = Get-IntText -Value $row.provider_channel_id -Default 0
        $canonicalChannel = if ([string]::IsNullOrWhiteSpace([string]$row.canonical_channel)) { $channel } else { [string]$row.canonical_channel }

        $sql = @"
INSERT INTO epg_programs
(
  id,
  epg_channel_id,
  title,
  description,
  start_time,
  end_time,
  catchup,
  provider,
  channel,
  provider_channel_id,
  canonical_channel
)
VALUES
(
  $stableId,
  $(Escape-Sql-Required $epgChannelId),
  $(Escape-Sql-Required $title),
  $(Escape-Sql $description),
  $(Escape-Sql-Required $startTime),
  $(Escape-Sql-Required $endTime),
  $catchup,
  $(Escape-Sql $provider),
  $(Escape-Sql-Required $channel),
  $providerChannelId,
  $(Escape-Sql $canonicalChannel)
)
ON DUPLICATE KEY UPDATE
  description = VALUES(description),
  catchup = VALUES(catchup),
  provider = VALUES(provider),
  channel = VALUES(channel),
  provider_channel_id = VALUES(provider_channel_id),
  canonical_channel = VALUES(canonical_channel);
"@

        if ($dryRun) {
            $results.Add([pscustomobject][ordered]@{
                apply_disposition = "would_apply"
                rows_affected = 0
                dry_run = $true
                epg_channel_id = $epgChannelId
                start_time = $startTime
                end_time = $endTime
                title = $title
                error_message = ""
            })
        }
        else {
            $response = Invoke-ApplySql -Sql $sql
            $applied++

            $results.Add([pscustomobject][ordered]@{
                apply_disposition = "apply_completed"
                rows_affected = ""
                dry_run = $false
                epg_channel_id = $epgChannelId
                start_time = $startTime
                end_time = $endTime
                title = $title
                error_message = ""
            })
        }

        if ([string]::IsNullOrWhiteSpace($maxEndTime) -or $endTime -gt $maxEndTime) {
            $maxEndTime = $endTime
        }
    }
    catch {
        $failed++

        $results.Add([pscustomobject][ordered]@{
            apply_disposition = "apply_failed"
            rows_affected = 0
            dry_run = $dryRun
            epg_channel_id = [string]$row.epg_channel_id
            start_time = [string]$row.start_time
            end_time = [string]$row.end_time
            title = [string]$row.title
            error_message = $_.Exception.Message
        })
    }
}

$results | Export-Csv -NoTypeInformation -Path $ApplyCsvPath -Encoding UTF8

$summary = [pscustomobject][ordered]@{
    run_id = $RunId
    provider = $Provider
    source_preview_csv = $PreviewCsvPath
    total_rows_seen = $seen
    would_write = $wouldWrite
    applied = $applied
    skipped = $skipped
    failed = $failed
    dry_run = $dryRun
    write_authorized = [bool]$authorization.authorized
    max_end_time_seen = $maxEndTime
    apply_csv_path = $ApplyCsvPath
    status = if ($failed -eq 0 -and $seen -gt 0) { "pass" } else { "warning" }
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Event @{
    event_type = "job_completed"
    status = $summary.status
    source_row_count = $seen
    would_write = $wouldWrite
    applied = $applied
    skipped = $skipped
    failed = $failed
    dry_run = $dryRun
    db_writes = [bool]$authorization.authorized
    provider_calls = $false
    summary_path = $SummaryPath
}

Write-Output "OK: EPG limited apply completed. dry_run=$dryRun would_write=$wouldWrite applied=$applied skipped=$skipped failed=$failed summary=$SummaryPath"
