<#
.SYNOPSIS
    Read-only inventory worker for the current MiraTV Master_Control integration.

.DESCRIPTION
    Scans the current/legacy integration root, usually C:\miratv_ingest, and writes
    redacted inventory outputs that can be used to map Master_Control, master_runner2,
    triggers, workers, folders, and remote endpoint relationships.

    This worker does not modify the current integration. It only reads files and
    writes report files to an output folder.

    Intended clean-repo location:
        tools\workers\inventory_master_control_integration.ps1

.NOTES
    This is not a credential rotation tool.
    This is not a migration tool.
    This is a read-only current-system inventory and relationship mapper.
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "inventory_master_control_integration",
    [string]$Component = "master_control_inventory",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_MASTER_CONTROL_INVENTORY",

    [string]$CurrentRoot = "C:\miratv_ingest",
    [string]$OutputRoot = "",

    [int]$MaxFiles = 0,
    [switch]$IncludeTextFiles,
    [switch]$IncludeJsonFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ScriptRepoRoot {
    [CmdletBinding()]
    param()

    $scriptDir = Split-Path -Parent $PSCommandPath
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue
    if ($null -ne $resolved) {
        return $resolved.Path
    }

    return (Get-Location).Path
}

function New-LocalRunId {
    [CmdletBinding()]
    param(
        [string]$Prefix = "master-control-inventory"
    )

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N")
    return "$Prefix-$stamp-$guid"
}

function New-DirectorySafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-RelativePathSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullName,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $rootText = $Root.TrimEnd("\")
    if ($FullName.StartsWith($rootText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullName.Substring($rootText.Length).TrimStart("\")
    }

    return $FullName
}

function ConvertTo-JsonSafeLocal {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,
        [int]$Depth = 8
    )

    try {
        return ($Value | ConvertTo-Json -Depth $Depth -Compress)
    }
    catch {
        return "{}"
    }
}

function Redact-MasterControlLine {
    [CmdletBinding()]
    param(
        [string]$Text = ""
    )

    $line = [string]$Text

    # Query-string secrets.
    $line = $line -replace '(?i)(token=)[^&''"\s]+', '$1REDACTED'
    $line = $line -replace '(?i)(username=)[^&''"\s]+', '$1REDACTED'
    $line = $line -replace '(?i)(password=)[^&''"\s]+', '$1REDACTED'
    $line = $line -replace '(?i)(user=)[^&''"\s]+', '$1REDACTED'
    $line = $line -replace '(?i)(pass=)[^&''"\s]+', '$1REDACTED'

    # Assignment-style secrets.
    $line = $line -replace '(?i)(\$?\w*(token|password|passwd|pwd|secret|api[_-]?key)\w*\s*=\s*)["''][^"'']+["'']', '$1"REDACTED"'
    $line = $line -replace '(?i)(\$?\w*(token|password|passwd|pwd|secret|api[_-]?key)\w*\s*=\s*)[^;#\r\n]+', '$1REDACTED'

    # Authorization/Bearer.
    $line = $line -replace '(?i)(Authorization\s*[:=]\s*)["'']?[^"'']+["'']?', '$1REDACTED'
    $line = $line -replace '(?i)(Bearer\s+)[A-Za-z0-9._\-]+', '$1REDACTED'

    # FTP URL credentials, if any.
    $line = $line -replace '(?i)(ftp://)([^:@/\s]+):([^@/\s]+)@', '$1REDACTED:REDACTED@'

    return $line.Trim()
}

function Get-FileRoleGuess {
    [CmdletBinding()]
    param(
        [string]$RelativePath = "",
        [string]$Name = "",
        [string]$Extension = ""
    )

    $rel = $RelativePath.ToLowerInvariant()
    $nameLower = $Name.ToLowerInvariant()

    if ($nameLower -match "master_control|master_contol") { return "master_control_surface" }
    if ($nameLower -match "master_runner") { return "runner_spine" }
    if ($rel -match "\\triggers\\") { return "trigger" }
    if ($rel -match "\\workers\\") { return "worker" }
    if ($rel -match "\\dashboard\\") { return "dashboard_surface" }
    if ($rel -match "\\docs\\|\\guides\\") { return "documentation" }
    if ($rel -match "\\archive\\|master_contol _ old") { return "archive_or_reference" }
    if ($rel -match "\\runtime\\|\\logs\\") { return "runtime_log_or_state" }
    if ($rel -match "\\raw_store\\|\\series_sep\\|\\processed\\|\\uploads\\|\\export\\|\\chunks\\|\\tmp\\") { return "data_or_runtime_artifact" }
    if ($Extension -eq ".php") { return "server_side_worker_reference" }
    if ($Extension -eq ".sql") { return "sql_or_db_asset" }
    if ($Extension -eq ".psm1") { return "powershell_module" }
    if ($Extension -eq ".bat" -or $Extension -eq ".cmd") { return "batch_or_launcher" }
    if ($Extension -eq ".ps1") { return "powershell_script" }

    return "unknown"
}

function Get-MatchFamily {
    [CmdletBinding()]
    param(
        [string]$Line = ""
    )

    $families = New-Object System.Collections.Generic.List[string]
    $text = [string]$Line

    if ($text -match "C:\\miratv_ingest") { $families.Add("current_root_path") }
    if ($text -match "C:\\miraTV_ingest_clean") { $families.Add("clean_root_path") }
    if ($text -match "miratv\.club") { $families.Add("miratv_endpoint") }
    if ($text -match "_workers") { $families.Add("workers_endpoint") }
    if ($text -match "_ingest") { $families.Add("ingest_endpoint") }
    if ($text -match "raw_store") { $families.Add("raw_store") }
    if ($text -match "series_sep") { $families.Add("series_sep") }
    if ($text -match "processed") { $families.Add("processed") }
    if ($text -match "Master_Control|Master_Contol") { $families.Add("master_control") }
    if ($text -match "master_runner") { $families.Add("master_runner") }
    if ($text -match "dog_open") { $families.Add("dog_open") }
    if ($text -match "dog_open_proc") { $families.Add("dog_open_proc") }
    if ($text -match "materialize") { $families.Add("materialize") }
    if ($text -match "ingest_series") { $families.Add("ingest_series") }
    if ($text -match "series_pipeline") { $families.Add("series_pipeline") }
    if ($text -match "import_epg") { $families.Add("epg_import") }
    if ($text -match "xmltv") { $families.Add("xmltv") }
    if ($text -match "token=|password|passwd|pwd|username|Authorization|Bearer|api_key|apikey|secret|X-Ingest-Token|ftp://") { $families.Add("secret_risk") }

    if ($families.Count -eq 0) {
        return ""
    }

    return ($families.ToArray() -join ",")
}

function Write-LocalJsonLine {
    [CmdletBinding()]
    param(
        [string]$Path,
        [hashtable]$Record
    )

    $dir = Split-Path -Parent $Path
    New-DirectorySafe -Path $dir
    $json = ConvertTo-JsonSafeLocal -Value $Record -Depth 12
    Add-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

$repoRoot = Get-ScriptRepoRoot
$runId = New-LocalRunId

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false

if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "runtime\reports\master_control_inventory"
}

New-DirectorySafe -Path $OutputRoot

$startedAt = Get-Date
$status = "unknown"
$errorMessage = ""
$signalName = "master_control_inventory_completed"

try {
    if ($loggingAvailable) {
        $kill = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true
        $killEnabled = $true
        if ($kill -is [bool]) {
            $killEnabled = [bool]$kill
        }
        elseif ($null -ne $kill -and ($kill.PSObject.Properties.Name -contains "enabled")) {
            $killEnabled = [bool]$kill.enabled
        }
        elseif ($null -ne $kill -and ($kill.PSObject.Properties.Name -contains "is_enabled")) {
            $killEnabled = [bool]$kill.is_enabled
        }

        if (-not $killEnabled) {
            Write-JobLog `
                -RunId $runId `
                -JobName $WorkerName `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -EventType "worker_blocked" `
                -Status "blocked" `
                -Data @{ event_message = "Kill switch disabled: $KillSwitchName"; current_root = $CurrentRoot; output_root = $OutputRoot; kill_switch = $KillSwitchName } | Out-Null

            Write-Output "BLOCKED: master control inventory worker blocked by kill switch. run_id=$runId"
            exit 0
        }

        Write-JobLog `
            -RunId $runId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_started" `
            -Status "started" `
            -Data @{ event_message = "Master_Control integration inventory started."; current_root = $CurrentRoot; output_root = $OutputRoot; max_files = $MaxFiles } | Out-Null
    }

    if (-not (Test-Path -LiteralPath $CurrentRoot)) {
        throw "CurrentRoot does not exist: $CurrentRoot"
    }

    $allowedExtensions = @(".ps1", ".psm1", ".bat", ".cmd", ".php", ".sql")
    if ($IncludeTextFiles) {
        $allowedExtensions += @(".md", ".txt", ".config", ".cfg", ".ini")
    }
    if ($IncludeJsonFiles) {
        $allowedExtensions += @(".json")
    }

    $allFiles = @(Get-ChildItem -LiteralPath $CurrentRoot -Recurse -File -ErrorAction SilentlyContinue)
    if ($MaxFiles -gt 0) {
        $allFiles = @($allFiles | Select-Object -First $MaxFiles)
    }

    $inventoryRows = foreach ($file in $allFiles) {
        $relative = Get-RelativePathSafe -FullName $file.FullName -Root $CurrentRoot
        [pscustomobject]@{
            full_name = $file.FullName
            relative_path = $relative
            top_folder = ($relative -split "\\")[0]
            name = $file.Name
            extension = $file.Extension
            length = $file.Length
            last_write_time = $file.LastWriteTime
            role_guess = Get-FileRoleGuess -RelativePath $relative -Name $file.Name -Extension $file.Extension.ToLowerInvariant()
        }
    }

    $scanFiles = @($allFiles | Where-Object { $allowedExtensions -contains $_.Extension.ToLowerInvariant() })

    $patterns = @(
        "C:\\miratv_ingest",
        "C:\\miraTV_ingest_clean",
        "miratv.club",
        "_workers",
        "_ingest",
        "raw_store",
        "series_sep",
        "processed",
        "Master_Control",
        "Master_Contol",
        "master_runner",
        "dog_open",
        "dog_open_proc",
        "materialize",
        "ingest_series",
        "series_pipeline",
        "import_epg",
        "xmltv",
        "token=",
        "password",
        "passwd",
        "pwd",
        "username",
        "Authorization",
        "Bearer",
        "api_key",
        "apikey",
        "secret",
        "X-Ingest-Token",
        "ftp://"
    )

    $matchRows = foreach ($file in $scanFiles) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -CaseSensitive:$false -ErrorAction SilentlyContinue
        foreach ($match in $matches) {
            $relative = Get-RelativePathSafe -FullName $match.Path -Root $CurrentRoot
            $redacted = Redact-MasterControlLine -Text $match.Line
            [pscustomobject]@{
                file = $match.Path
                relative_path = $relative
                top_folder = ($relative -split "\\")[0]
                line_number = $match.LineNumber
                match_family = Get-MatchFamily -Line $match.Line
                redacted_line = $redacted
            }
        }
    }

    $folderRows = Get-ChildItem -LiteralPath $CurrentRoot -Directory -ErrorAction SilentlyContinue |
        Select-Object FullName, LastWriteTime

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $inventoryCsv = Join-Path $OutputRoot "master_control_file_inventory_$timestamp.csv"
    $matchesCsv = Join-Path $OutputRoot "master_control_path_endpoint_inventory_$timestamp.csv"
    $foldersCsv = Join-Path $OutputRoot "master_control_top_level_folders_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "master_control_inventory_summary_$timestamp.json"

    $inventoryRows | Export-Csv -LiteralPath $inventoryCsv -NoTypeInformation -Encoding UTF8
    $matchRows | Export-Csv -LiteralPath $matchesCsv -NoTypeInformation -Encoding UTF8
    $folderRows | Export-Csv -LiteralPath $foldersCsv -NoTypeInformation -Encoding UTF8

    $topFolders = @($inventoryRows | Group-Object top_folder | Sort-Object Count -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{ folder = $_.Name; count = $_.Count }
    })

    $roleCounts = @($inventoryRows | Group-Object role_guess | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ role = $_.Name; count = $_.Count }
    })

    $familyCounts = @($matchRows | ForEach-Object {
        $families = ([string]$_.match_family).Split(",", [System.StringSplitOptions]::RemoveEmptyEntries)
        foreach ($family in $families) { $family }
    } | Group-Object | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ family = $_.Name; count = $_.Count }
    })

    $secretRiskFiles = @($matchRows | Where-Object { ([string]$_.match_family) -like "*secret_risk*" } | Select-Object -ExpandProperty relative_path -Unique)

    $summary = [pscustomobject]@{
        run_id = $runId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        current_root = $CurrentRoot
        output_root = $OutputRoot
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        total_files = @($allFiles).Count
        scanned_files = @($scanFiles).Count
        top_level_folders = @($folderRows).Count
        match_rows = @($matchRows).Count
        files_with_matches = @($matchRows | Select-Object -ExpandProperty relative_path -Unique).Count
        secret_risk_files = @($secretRiskFiles).Count
        inventory_csv = $inventoryCsv
        path_endpoint_inventory_csv = $matchesCsv
        top_level_folders_csv = $foldersCsv
        top_folders = $topFolders
        role_counts = $roleCounts
        match_family_counts = $familyCounts
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds
    $status = "pass"

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $runId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status "pass" `
            -Data @{
                event_message = "Master_Control integration inventory completed."
                current_root = $CurrentRoot
                output_root = $OutputRoot
                total_files = $summary.total_files
                scanned_files = $summary.scanned_files
                match_rows = $summary.match_rows
                files_with_matches = $summary.files_with_matches
                secret_risk_files = $summary.secret_risk_files
                duration_ms = $durationMs
            } | Out-Null

        Emit-Signal `
            -RunId $runId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -Data @{
                current_root = $CurrentRoot
                output_root = $OutputRoot
                summary_json = $summaryJson
                total_files = $summary.total_files
                scanned_files = $summary.scanned_files
                match_rows = $summary.match_rows
                files_with_matches = $summary.files_with_matches
                secret_risk_files = $summary.secret_risk_files
            } | Out-Null
    }

    Write-Output ("OK: master control inventory completed. status=pass total_files={0} scanned_files={1} match_rows={2} files_with_matches={3} secret_risk_files={4} output_root=""{5}"" run_id={6}" -f `
        $summary.total_files, `
        $summary.scanned_files, `
        $summary.match_rows, `
        $summary.files_with_matches, `
        $summary.secret_risk_files, `
        $OutputRoot, `
        $runId)

    Write-Output ("FILES: inventory_csv=""{0}"" path_endpoint_inventory_csv=""{1}"" top_level_folders_csv=""{2}"" summary_json=""{3}""" -f `
        $inventoryCsv, `
        $matchesCsv, `
        $foldersCsv, `
        $summaryJson)
}
catch {
    $status = "failed"
    $errorMessage = $_.Exception.Message

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $runId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_failed" `
            -Status "failed" `
            -Data @{
                event_message = "Master_Control integration inventory failed."
                current_root = $CurrentRoot
                output_root = $OutputRoot
                error = $errorMessage
            } | Out-Null

        Emit-Signal `
            -RunId $runId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -Data @{
                event_message = "Master_Control integration inventory failed."
                current_root = $CurrentRoot
                output_root = $OutputRoot
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: master control inventory failed. run_id=$runId error=$errorMessage"
    exit 1
}
