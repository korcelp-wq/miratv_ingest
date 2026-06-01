[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"



function Write-JobLog {
    param(
        [string]$EventName,
        [string]$Status,
        [object]$Data = $null
    )

    Write-Host "LOG: $EventName status=$Status"
}

function Emit-Heartbeat {
    param([string]$Status = "ok")
    Write-JobLog -EventName "heartbeat" -Status $Status
}

function Emit-Signal {
    param(
        [string]$SignalName,
        [string]$SignalValue = "ok"
    )

    Write-JobLog -EventName "signal_emitted" -Status $SignalValue -Data ([ordered]@{
        signal_name = $SignalName
    })
}

function Test-KillSwitch {
    return $true
}
$ManifestPath = ".\tools\config\master_control_ingest_manifest.csv"
$WorkerPath = ".\tools\workers\run_epg_pipeline.ps1"

if (-not (Test-Path $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

if (-not (Test-Path $WorkerPath)) {
    throw "Worker not found: $WorkerPath"
}

$rows = @(Import-Csv $ManifestPath)

$exists = @(
    $rows | Where-Object {
        $_.lane -eq "epg_refresh" -and
        $_.step_order -eq "EPG-GOVERNED" -and
        $_.actual_file_hint -eq "run_epg_pipeline.ps1"
    }
).Count -gt 0

if ($exists) {
    Write-Host "OK: governed EPG pipeline already registered."
}
else {
    $newRow = [pscustomobject][ordered]@{
        lane = "epg_refresh"
        step_order = "EPG-GOVERNED"
        parent_file_uploaded = "run_epg_pipeline.ps1"
        actual_file_hint = "run_epg_pipeline.ps1"
        current_relative_path = "tools\workers\run_epg_pipeline.ps1"
        current_absolute_path = "C:\miraTV_ingest_clean\tools\workers\run_epg_pipeline.ps1"
        role = "epg_pipeline_runner"
        execution_type = "governed_orchestrator"
        purpose = "Governed EPG acquisition, upload, and import pipeline."
        subfile_count = "3"
        subfiles_uploaded = "pull_epg_xml.ps1; upload_epg_xml_to_server.ps1; run_epg_server_import_queue.ps1"
        clean_repo_target = "active"
        migration_status = "current_system_evidence"
        contract_gap = "contract_complete"
        secret_risk = "token_risk"
    }

    $rows + $newRow | Export-Csv -NoTypeInformation -Path $ManifestPath -Encoding UTF8
    Write-Host "OK: governed EPG pipeline registered."
}

$check = @(Import-Csv $ManifestPath | Where-Object {
    $_.lane -eq "epg_refresh" -and
    $_.step_order -eq "EPG-GOVERNED"
})

if ($check.Count -ne 1) {
    throw "Validator failed: expected exactly one EPG-GOVERNED row, found $($check.Count)."
}

$required = @(
    "pull_epg_xml.ps1",
    "upload_epg_xml_to_server.ps1",
    "run_epg_server_import_queue.ps1"
)

foreach ($file in $required) {
    $path = Join-Path ".\tools\workers" $file
    if (-not (Test-Path $path)) {
        throw "Validator failed: missing worker $path"
    }
}

Write-Host "PASS: manifest registration validator passed."

