<#
.SYNOPSIS
    Validates the Master_Control ingest manifest against the current-system folder.

.DESCRIPTION
    Reads tools\config\master_control_ingest_manifest.json and checks whether local
    current-system files exist under C:\miratv_ingest.

    This is a utility, not a governed worker:
      - no DB writes
      - no current-system writes
      - no contract entry required
      - no runtime mutation

    Intended clean-repo location:
      tools\utilities\validate_master_control_ingest_manifest.ps1
#>

[CmdletBinding()]
param(
    [string]$ManifestPath = "",
    [string]$CurrentRoot = "C:\miratv_ingest",
    [string]$OutputPath = "",
    [switch]$IncludeServerPaths
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-UtilityRepoRoot {
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

function New-DirectoryIfMissingLocal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Convert-ToArrayLocal {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-ManifestFilenameCandidates {
    [CmdletBinding()]
    param(
        [string]$UploadedFile = "",
        [string]$ActualFileHint = ""
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($rawName in @($ActualFileHint, $UploadedFile)) {
        if ([string]::IsNullOrWhiteSpace($rawName)) {
            continue
        }

        $name = [System.IO.Path]::GetFileName($rawName.Trim())
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (-not $candidates.Contains($name)) {
            $candidates.Add($name)
        }

        $ext = [System.IO.Path]::GetExtension($name)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)

        # Remove review suffix after whitespace: "Query_Content2  12-1.ps1" -> "Query_Content2.ps1"
        $trimmedSpaceSuffix = ($base -replace '\s+\d+(?:-\d+)?$', '') + $ext
        if (-not [string]::IsNullOrWhiteSpace($trimmedSpaceSuffix) -and -not $candidates.Contains($trimmedSpaceSuffix)) {
            $candidates.Add($trimmedSpaceSuffix)
        }

        # Remove parent-sub suffix: "raw_router_worker3-1.ps1" -> "raw_router_worker.ps1"
        $trimmedParentSub = ($base -replace '\d+-\d+$', '') + $ext
        if (-not [string]::IsNullOrWhiteSpace($trimmedParentSub) -and -not $candidates.Contains($trimmedParentSub)) {
            $candidates.Add($trimmedParentSub)
        }

        # Remove one trailing order number: "03_raw_router_trigger3.ps1" -> "03_raw_router_trigger.ps1"
        # Preserve base names whose number is intentionally part of the name when an explicit actual hint exists.
        $trimmedOneNumber = ($base -replace '(?<!\d)\d+$', '') + $ext
        if (-not [string]::IsNullOrWhiteSpace($trimmedOneNumber) -and -not $candidates.Contains($trimmedOneNumber)) {
            $candidates.Add($trimmedOneNumber)
        }

        # Remove a trailing review step suffix after a literal space even if there are multiple spaces.
        $trimmedLooseStep = ($base -replace '\s+\d+\-\d+$', '') + $ext
        if (-not [string]::IsNullOrWhiteSpace($trimmedLooseStep) -and -not $candidates.Contains($trimmedLooseStep)) {
            $candidates.Add($trimmedLooseStep)
        }
    }

    return @($candidates.ToArray())
}

function Resolve-ManifestLocalPath {
    [CmdletBinding()]
    param(
        [string]$CurrentRoot = "",
        [string]$CurrentAbsolutePath = "",
        [string]$CurrentRelativePath = "",
        [string]$UploadedFile = "",
        [string]$ActualFileHint = ""
    )

    $checked = New-Object System.Collections.Generic.List[string]

    function Add-CheckedPath {
        param([string]$PathValue)
        if (-not [string]::IsNullOrWhiteSpace($PathValue) -and -not $checked.Contains($PathValue)) {
            $checked.Add($PathValue)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentAbsolutePath)) {
        Add-CheckedPath -PathValue $CurrentAbsolutePath
        if (Test-Path -LiteralPath $CurrentAbsolutePath) {
            return [pscustomobject]@{
                exists = $true
                resolved_path = $CurrentAbsolutePath
                resolution_method = "manifest_absolute_path"
                checked_paths = @($checked.ToArray())
                candidate_names = @()
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentRelativePath) -and -not [string]::IsNullOrWhiteSpace($CurrentRoot)) {
        $relPath = Join-Path $CurrentRoot $CurrentRelativePath
        Add-CheckedPath -PathValue $relPath
        if (Test-Path -LiteralPath $relPath) {
            return [pscustomobject]@{
                exists = $true
                resolved_path = $relPath
                resolution_method = "manifest_relative_path"
                checked_paths = @($checked.ToArray())
                candidate_names = @()
            }
        }
    }

    $candidateNames = @(Get-ManifestFilenameCandidates -UploadedFile $UploadedFile -ActualFileHint $ActualFileHint)

    $searchRoots = @(
        $CurrentRoot,
        (Join-Path $CurrentRoot "triggers"),
        (Join-Path $CurrentRoot "workers")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($candidateName in $candidateNames) {
        foreach ($root in $searchRoots) {
            $candidatePath = Join-Path $root $candidateName
            Add-CheckedPath -PathValue $candidatePath
            if (Test-Path -LiteralPath $candidatePath) {
                return [pscustomobject]@{
                    exists = $true
                    resolved_path = $candidatePath
                    resolution_method = "nomenclature_direct_search"
                    checked_paths = @($checked.ToArray())
                    candidate_names = $candidateNames
                }
            }
        }
    }

    foreach ($candidateName in $candidateNames) {
        $found = Get-ChildItem -LiteralPath $CurrentRoot -Recurse -File -Filter $candidateName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) {
            return [pscustomobject]@{
                exists = $true
                resolved_path = $found.FullName
                resolution_method = "nomenclature_recursive_search"
                checked_paths = @($checked.ToArray())
                candidate_names = $candidateNames
            }
        }
    }

    return [pscustomobject]@{
        exists = $false
        resolved_path = ""
        resolution_method = "not_found"
        checked_paths = @($checked.ToArray())
        candidate_names = $candidateNames
    }
}


function Test-ManifestPathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,

        [string]$Lane = "",
        [string]$ParentStep = "",
        [string]$CurrentRoot = "",
        [switch]$IncludeServerPaths
    )

    $absolute = if ($Entry.PSObject.Properties.Name -contains "current_absolute_path") { [string]$Entry.current_absolute_path } else { "" }
    $relative = if ($Entry.PSObject.Properties.Name -contains "current_relative_path") { [string]$Entry.current_relative_path } else { "" }
    $actualHint = if ($Entry.PSObject.Properties.Name -contains "actual_file_hint") { [string]$Entry.actual_file_hint } else { "" }

    $uploaded = ""
    if ($Entry.PSObject.Properties.Name -contains "parent_file_uploaded") {
        $uploaded = [string]$Entry.parent_file_uploaded
    }
    elseif ($Entry.PSObject.Properties.Name -contains "uploaded_file") {
        $uploaded = [string]$Entry.uploaded_file
    }

    $isServer = $absolute.StartsWith("server:", [System.StringComparison]::OrdinalIgnoreCase)
    $isRemote = $absolute.StartsWith("http", [System.StringComparison]::OrdinalIgnoreCase)
    $checkable = -not $isServer -and -not $isRemote

    if ($isServer -and $IncludeServerPaths) {
        $checkable = $false
    }

    $exists = $false
    $resolvedPath = $absolute
    $resolutionMethod = ""
    $candidateNames = @()

    if ($checkable) {
        $resolution = Resolve-ManifestLocalPath `
            -CurrentRoot $CurrentRoot `
            -CurrentAbsolutePath $absolute `
            -CurrentRelativePath $relative `
            -UploadedFile $uploaded `
            -ActualFileHint $actualHint

        $exists = [bool]$resolution.exists
        if (-not [string]::IsNullOrWhiteSpace([string]$resolution.resolved_path)) {
            $resolvedPath = [string]$resolution.resolved_path
        }
        $resolutionMethod = [string]$resolution.resolution_method
        $candidateNames = @($resolution.candidate_names)
    }

    [pscustomobject]@{
        lane = $Lane
        parent_step = $ParentStep
        step_order = if ($Entry.PSObject.Properties.Name -contains "step_order") { [string]$Entry.step_order } else { "" }
        sub_order = if ($Entry.PSObject.Properties.Name -contains "sub_order") { [string]$Entry.sub_order } else { "" }
        role = if ($Entry.PSObject.Properties.Name -contains "role") { [string]$Entry.role } else { "" }
        uploaded_file = $uploaded
        actual_file_hint = if ($Entry.PSObject.Properties.Name -contains "actual_file_hint") { [string]$Entry.actual_file_hint } else { "" }
        current_relative_path = $relative
        current_absolute_path = $absolute
        resolved_absolute_path = $resolvedPath
        resolution_method = $resolutionMethod
        candidate_names = ($candidateNames -join "; ")
        path_type = if ($isServer) { "server" } elseif ($isRemote) { "remote_url" } elseif ($checkable) { "local" } else { "unknown" }
        exists = if ($checkable) { [bool]$exists } else { $null }
        check_status = if ($checkable -and $exists) { "present" } elseif ($checkable -and -not $exists) { "missing" } elseif ($isServer) { "server_path_not_checked" } elseif ($isRemote) { "remote_url_not_checked" } else { "not_checkable" }
        migration_status = if ($Entry.PSObject.Properties.Name -contains "migration_status") { [string]$Entry.migration_status } else { "" }
        contract_gap = if ($Entry.PSObject.Properties.Name -contains "contract_gap") { [string]$Entry.contract_gap } else { "" }
        secret_risk = if ($Entry.PSObject.Properties.Name -contains "secret_risk") { [string]$Entry.secret_risk } else { "" }
    }
}

$repoRoot = Get-UtilityRepoRoot

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot "tools\config\master_control_ingest_manifest.json"
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportDir = Join-Path $repoRoot "runtime\reports\master_control_manifest_validation"
    New-DirectoryIfMissingLocal -Path $reportDir
    $OutputPath = Join-Path $reportDir "master_control_ingest_manifest_validation_$stamp.csv"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

$rows = @()

$laneNames = @(
    $manifest.PSObject.Properties.Name |
        Where-Object {
            $_ -like "*_lane" -or
            $_ -eq "provider_pull_spine"
        }
)

foreach ($laneName in $laneNames) {
    foreach ($step in Convert-ToArrayLocal -Value $manifest.$laneName) {
        $stepLabel = if ($step.PSObject.Properties.Name -contains "step_order") { [string]$step.step_order } else { "" }

        $rows += Test-ManifestPathEntry `
            -Entry $step `
            -Lane $laneName `
            -ParentStep $stepLabel `
            -CurrentRoot $CurrentRoot `
            -IncludeServerPaths:$IncludeServerPaths

        foreach ($sub in Convert-ToArrayLocal -Value $step.subfiles) {
            $rows += Test-ManifestPathEntry `
                -Entry $sub `
                -Lane $laneName `
                -ParentStep $stepLabel `
                -CurrentRoot $CurrentRoot `
                -IncludeServerPaths:$IncludeServerPaths
        }
    }
}

$outDir = Split-Path -Parent $OutputPath
New-DirectoryIfMissingLocal -Path $outDir

$rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8


$total = @($rows).Count
$localRows = @($rows | Where-Object { $_.path_type -eq "local" })
$present = @($localRows | Where-Object { $_.exists -eq $true }).Count
$missing = @($localRows | Where-Object { $_.exists -eq $false }).Count
$server = @($rows | Where-Object { $_.path_type -eq "server" }).Count
$remote = @($rows | Where-Object { $_.path_type -eq "remote_url" }).Count
$secretRisk = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.secret_risk) -and [string]$_.secret_risk -ne "low_to_unknown" }).Count

Write-Output ("OK: manifest validation completed. total_entries={0} local_entries={1} local_present={2} local_missing={3} server_entries={4} remote_entries={5} secret_risk_entries={6}" -f `
    $total, @($localRows).Count, $present, $missing, $server, $remote, $secretRisk)

Write-Output ("REPORT: {0}" -f $OutputPath)

if ($missing -gt 0) {
    Write-Output "MISSING LOCAL PATHS:"
    $rows |
        Where-Object { $_.path_type -eq "local" -and $_.exists -eq $false } |
        Select-Object lane, parent_step, sub_order, role, uploaded_file, current_absolute_path |
        Format-Table -AutoSize
}
