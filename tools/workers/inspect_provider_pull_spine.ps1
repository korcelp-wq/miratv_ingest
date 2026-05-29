<#
.SYNOPSIS
    Inspect provider pull spine files without running them.

.DESCRIPTION
    Read-only inspector for provider_pull_spine in tools\config\master_control_ingest_manifest.json.

    This worker does not:
      - call providers
      - call endpoints
      - write DB data
      - upload files
      - mutate current-system files

    It only reads current-system files and writes runtime reports.
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "inspect_provider_pull_spine",
    [string]$Component = "provider_pull_spine",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_PROVIDER_PULL_SPINE_INSPECTION",

    [string]$ManifestPath = "",
    [string]$OutputRoot = "runtime/reports/provider_pull_spine_inspection",
    [int]$MaxSnippetLength = 260
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
    param([string]$Prefix = "provider-pull-spine-inspection")
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

function Convert-ToArrayLocal {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [array]) { return @($Value) }
    return @($Value)
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

function Redact-InspectionTextLocal {
    param([string]$Text = "")

    $value = [string]$Text
    $value = $value -replace '(?i)(token=)[^&''"\s]+', '$1REDACTED'
    $value = $value -replace '(?i)(username=)[^&''"\s]+', '$1REDACTED'
    $value = $value -replace '(?i)(password=)[^&''"\s]+', '$1REDACTED'
    $value = $value -replace '(?i)(user=)[^&''"\s]+', '$1REDACTED'
    $value = $value -replace '(?i)(pass=)[^&''"\s]+', '$1REDACTED'
    $value = $value -replace '(?i)(provider_username\s*=\s*)["''][^"'']+["'']', '$1"REDACTED"'
    $value = $value -replace '(?i)(provider_password\s*=\s*)["''][^"'']+["'']', '$1"REDACTED"'
    $value = $value -replace '(?i)(\$?\w*(username|password|token|secret|api[_-]?key)\w*\s*=\s*)["''][^"'']+["'']', '$1"REDACTED"'
    $value = $value -replace '(?i)(Bearer\s+)[A-Za-z0-9._\-]+', '$1REDACTED'
    return $value
}

function Get-TextValueLocal {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) { return "" }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return [string]$Object.$name
        }
    }

    return ""
}

function Get-MediaTypeFromTextLocal {
    param([string]$Text = "")
    $value = ([string]$Text).ToLowerInvariant()
    if ($value -match "epg|xmltv") { return "epg" }
    if ($value -match "live") { return "live" }
    if ($value -match "vod|movie") { return "vod" }
    if ($value -match "series") { return "series" }
    return "general"
}

function Get-AcquisitionGroupLocal {
    param([object]$Entry)

    $order = Get-TextValueLocal -Object $Entry -Names @("step_order", "sub_order")
    $role = Get-TextValueLocal -Object $Entry -Names @("role")
    $name = Get-TextValueLocal -Object $Entry -Names @("parent_file_uploaded", "uploaded_file")
    $path = Get-TextValueLocal -Object $Entry -Names @("current_absolute_path", "current_relative_path")
    $basis = "$order $role $name $path".ToLowerInvariant()

    if ($basis -match "state|\.last") { return "state_marker" }
    if ($basis -match "import|call") { return "import_call" }
    if ($basis -match "trigger") { return "pull_trigger" }
    if ($basis -match "worker") { return "pull_worker" }
    if ($basis -match "orchestrator|master") { return "pull_orchestrator" }
    return "manifest_entry"
}

function Get-SpineEntriesLocal {
    param([object]$Manifest)

    $entries = @()

    if (-not ($Manifest.PSObject.Properties.Name -contains "provider_pull_spine")) {
        return @()
    }

    foreach ($step in Convert-ToArrayLocal -Value $Manifest.provider_pull_spine) {
        $stepOrder = Get-TextValueLocal -Object $step -Names @("step_order")

        $entries += [pscustomobject]@{
            parent_step = $stepOrder
            sub_order = ""
            entry = $step
        }

        foreach ($sub in Convert-ToArrayLocal -Value $step.subfiles) {
            $entries += [pscustomobject]@{
                parent_step = $stepOrder
                sub_order = (Get-TextValueLocal -Object $sub -Names @("sub_order"))
                entry = $sub
            }
        }
    }

    return @($entries)
}

function Get-PatternFamiliesLocal {
    param([string]$Line = "")

    $families = @()
    $text = [string]$Line

    if ($text -match '(?i)player_api\.php') { $families += "xtream_player_api" }
    if ($text -match '(?i)get_live_streams|get_live_categories|/live/') { $families += "live_pull" }
    if ($text -match '(?i)get_vod_streams|get_vod_categories|get_vod_info|/movie/') { $families += "vod_pull" }
    if ($text -match '(?i)get_series|get_series_info|get_series_categories|/series/') { $families += "series_pull" }
    if ($text -match '(?i)xmltv\.php|epg\.xml|xmltv|import_epg') { $families += "epg_pull" }
    if ($text -match '(?i)Invoke-WebRequest|Invoke-RestMethod|curl\.exe|WebClient|DownloadFile|Start-BitsTransfer') { $families += "http_client" }
    if ($text -match '(?i)provider_dns|provider_url|provider_username|provider_password|xtream|m3u|m3u_plus') { $families += "provider_config" }
    if ($text -match '(?i)raw\\|raw/|raw_store|series_sep|processed|chunks|state\\|\.last') { $families += "local_pipeline_path" }
    if ($text -match '(?i)token=|username=|password=|provider_password|provider_username|Authorization|Bearer') { $families += "secret_risk" }
    if ($text -match '(?i)eldervpn|silvervpn|hmisjaiu|uxurwymd|miratv\.club|:8080') { $families += "domain_reference" }

    return @($families | Sort-Object -Unique)
}

function Get-ProviderActionsLocal {
    param([string]$Text = "")

    $actions = @()

    foreach ($m in [regex]::Matches([string]$Text, '(?i)(?:action=)([A-Za-z0-9_]+)')) {
        $action = [string]$m.Groups[1].Value
        if (-not [string]::IsNullOrWhiteSpace($action)) { $actions += $action }
    }

    foreach ($literal in @("get_live_streams", "get_live_categories", "get_vod_streams", "get_vod_categories", "get_vod_info", "get_series", "get_series_info", "get_series_categories")) {
        if ($Text -match [regex]::Escape($literal)) { $actions += $literal }
    }

    return @($actions | Sort-Object -Unique)
}

function Get-DomainReferencesLocal {
    param([string]$Text = "")

    $domains = @()

    foreach ($m in [regex]::Matches([string]$Text, '(?i)\b(?:https?://)?([A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?')) {
        $domain = ([string]$m.Groups[1].Value).ToLowerInvariant()
        if ($domain -in @("aka.ms", "microsoft.com", "github.com")) { continue }
        $domains += $domain
    }

    return @($domains | Sort-Object -Unique)
}

function Test-LineHasAnyPatternLocal {
    param(
        [string]$Line = "",
        [string[]]$Patterns = @()
    )

    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Line.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot "tools\config\master_control_ingest_manifest.json"
}

$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$startedAt = Get-Date
$signalName = "provider_pull_spine_inspection_completed"

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
                    event_message = "Provider pull spine inspection blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                    manifest_path = $ManifestPath
                } | Out-Null

            Write-Output "BLOCKED: provider pull spine inspection blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
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
                event_message = "Provider pull spine inspection started."
                manifest_path = $ManifestPath
                read_only = $true
            } | Out-Null
    }

    $script:Stage = "read_manifest"
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Master Control ingest manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $entries = @(Get-SpineEntriesLocal -Manifest $manifest)

    $fileRows = @()
    $matchRows = @()

    $literalPatterns = @(
        "player_api.php",
        "xmltv.php",
        "get_live_streams",
        "get_live_categories",
        "get_vod_streams",
        "get_vod_categories",
        "get_vod_info",
        "get_series",
        "get_series_info",
        "get_series_categories",
        "Invoke-WebRequest",
        "Invoke-RestMethod",
        "curl.exe",
        "WebClient",
        "DownloadFile",
        "Start-BitsTransfer",
        "provider_dns",
        "provider_url",
        "provider_username",
        "provider_password",
        "username=",
        "password=",
        "token=",
        "Authorization",
        "Bearer",
        "raw_store",
        "raw\",
        "chunks",
        "series_sep",
        "processed",
        ".last",
        "eldervpn",
        "silvervpn",
        "miratv.club",
        ":8080"
    )

    $script:Stage = "inspect_entries"
    foreach ($entryWrapper in $entries) {
        $entry = $entryWrapper.entry

        $path = Get-TextValueLocal -Object $entry -Names @("current_absolute_path")
        $name = Get-TextValueLocal -Object $entry -Names @("parent_file_uploaded", "uploaded_file")
        $role = Get-TextValueLocal -Object $entry -Names @("role")
        $group = Get-AcquisitionGroupLocal -Entry $entry
        $media = Get-MediaTypeFromTextLocal -Text "$name $role $path"
        $exists = $false
        $isFile = $false
        $isDirectory = $false
        $length = 0
        $lastWrite = ""
        $content = ""

        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $exists = $true
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue

            if ($null -ne $item) {
                $isFile = -not [bool]$item.PSIsContainer
                $isDirectory = [bool]$item.PSIsContainer
                $lastWrite = $item.LastWriteTime.ToString("o")

                if ($isFile) {
                    $length = [int64]$item.Length
                    $content = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
                }
            }
        }

        $actions = @()
        $domains = @()
        $families = @()

        if ($isFile) {
            $actions = @(Get-ProviderActionsLocal -Text $content)
            $domains = @(Get-DomainReferencesLocal -Text $content)
            $families = @(Get-PatternFamiliesLocal -Line $content)
        }

        $fileRows += [pscustomobject]@{
            parent_step = [string]$entryWrapper.parent_step
            sub_order = [string]$entryWrapper.sub_order
            media_type = $media
            acquisition_group = $group
            role = $role
            file_name = $name
            current_absolute_path = $path
            exists = [bool]$exists
            is_file = [bool]$isFile
            is_directory = [bool]$isDirectory
            length = $length
            last_write_time = $lastWrite
            provider_actions = ($actions -join ";")
            domain_references = ($domains -join ";")
            pattern_families = ($families -join ";")
            secret_risk = [bool]($families -contains "secret_risk")
            domain_risk = [bool]($families -contains "domain_reference")
            read_only_inspection = $true
        }

        if ($isFile) {
            $script:Stage = "scan_file:$path"
            $lineNumber = 0
            foreach ($lineRaw in Get-Content -LiteralPath $path -ErrorAction SilentlyContinue) {
                $lineNumber++
                $lineText = [string]$lineRaw
                if (-not (Test-LineHasAnyPatternLocal -Line $lineText -Patterns $literalPatterns)) {
                    continue
                }

                $line = Redact-InspectionTextLocal -Text $lineText.Trim()
                if ($line.Length -gt $MaxSnippetLength) {
                    $line = $line.Substring(0, $MaxSnippetLength) + "..."
                }

                $lineFamilies = @(Get-PatternFamiliesLocal -Line $lineText)

                $matchRows += [pscustomobject]@{
                    parent_step = [string]$entryWrapper.parent_step
                    sub_order = [string]$entryWrapper.sub_order
                    media_type = $media
                    acquisition_group = $group
                    role = $role
                    file_name = $name
                    current_absolute_path = $path
                    line_number = $lineNumber
                    families = ($lineFamilies -join ";")
                    redacted_line = $line
                }
            }
            $script:Stage = "inspect_entries"
        }
    }

    $script:Stage = "write_reports"
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $fileSummaryCsv = Join-Path $outputRootFull "provider_pull_spine_file_summary_$stamp.csv"
    $matchesCsv = Join-Path $outputRootFull "provider_pull_spine_matches_$stamp.csv"
    $summaryJson = Join-Path $outputRootFull "provider_pull_spine_inspection_summary_$stamp.json"

    $fileRows | Export-Csv -LiteralPath $fileSummaryCsv -NoTypeInformation -Encoding UTF8
    $matchRows | Export-Csv -LiteralPath $matchesCsv -NoTypeInformation -Encoding UTF8

    $mediaCounts = @(
        $fileRows |
            Group-Object media_type |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ media_type = $_.Name; count = $_.Count } }
    )

    $groupCounts = @(
        $fileRows |
            Group-Object acquisition_group |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ acquisition_group = $_.Name; count = $_.Count } }
    )

    $actionValues = @()
    foreach ($row in $fileRows) {
        $txt = [string]$row.provider_actions
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        foreach ($part in @($txt -split ";")) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $actionValues += $part }
        }
    }

    $domainValues = @()
    foreach ($row in $fileRows) {
        $txt = [string]$row.domain_references
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        foreach ($part in @($txt -split ";")) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $domainValues += $part }
        }
    }

    $actionCounts = @(
        $actionValues |
            Group-Object |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ provider_action = $_.Name; count = $_.Count } }
    )

    $domainCounts = @(
        $domainValues |
            Group-Object |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ domain = $_.Name; count = $_.Count } }
    )

    $summary = [pscustomobject]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        read_only = $true
        manifest_path = $ManifestPath
        entries_seen = @($entries).Count
        files_present = @($fileRows | Where-Object { $_.exists -eq $true }).Count
        files_missing = @($fileRows | Where-Object { $_.exists -ne $true }).Count
        match_rows = @($matchRows).Count
        secret_risk_files = @($fileRows | Where-Object { $_.secret_risk -eq $true }).Count
        domain_risk_files = @($fileRows | Where-Object { $_.domain_risk -eq $true }).Count
        media_counts = $mediaCounts
        acquisition_group_counts = $groupCounts
        provider_action_counts = $actionCounts
        domain_counts = $domainCounts
        file_summary_csv = $fileSummaryCsv
        matches_csv = $matchesCsv
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    if ($loggingAvailable) {
        $script:Stage = "emit_success"
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status "pass" `
            -Data @{
                event_message = "Provider pull spine inspection completed."
                read_only = $true
                entries_seen = $summary.entries_seen
                files_present = $summary.files_present
                files_missing = $summary.files_missing
                match_rows = $summary.match_rows
                secret_risk_files = $summary.secret_risk_files
                domain_risk_files = $summary.domain_risk_files
                duration_ms = $durationMs
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue "pass" `
            -Status "pass" `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/inspect_provider_pull_spine.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.pull.spine.inspection"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                read_only = $true
                entries_seen = $summary.entries_seen
                files_present = $summary.files_present
                files_missing = $summary.files_missing
                match_rows = $summary.match_rows
                secret_risk_files = $summary.secret_risk_files
                domain_risk_files = $summary.domain_risk_files
                file_summary_csv = $fileSummaryCsv
                matches_csv = $matchesCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: provider pull spine inspection completed. status=pass read_only=True entries_seen={0} files_present={1} files_missing={2} match_rows={3} secret_risk_files={4} domain_risk_files={5} output_root=""{6}"" run_id={7}" -f `
        $summary.entries_seen, `
        $summary.files_present, `
        $summary.files_missing, `
        $summary.match_rows, `
        $summary.secret_risk_files, `
        $summary.domain_risk_files, `
        $outputRootFull, `
        $script:RunId)

    Write-Output ("FILES: file_summary_csv=""{0}"" matches_csv=""{1}"" summary_json=""{2}""" -f $fileSummaryCsv, $matchesCsv, $summaryJson)
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
                event_message = "Provider pull spine inspection failed."
                error = $errorMessage
                manifest_path = $ManifestPath
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
            -SourceTableOrEndpoint "tools/workers/inspect_provider_pull_spine.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.pull.spine.inspection"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: provider pull spine inspection failed. run_id=$script:RunId $errorMessage"
    exit 1
}
