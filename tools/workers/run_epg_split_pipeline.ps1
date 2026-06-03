<#
.SYNOPSIS
  EPG Split Pipeline Orchestrator.

.DESCRIPTION
  Runs the separated EPG gates:
    - download
    - upload
    - db import/upsert

  Use switches to skip stages safely.

.EXAMPLES
  Full path:
    .\tools\workers\run_epg_split_pipeline.ps1

  Retry only DB import/upsert against already uploaded server file:
    .\tools\workers\run_epg_split_pipeline.ps1 -SkipDownload -SkipUpload

  Continue DB import without resetting importer offset:
    .\tools\workers\run_epg_split_pipeline.ps1 -SkipDownload -SkipUpload -NoResetImport
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$RepoRoot = "",
    [string]$DownloadWorker = ".\tools\workers\run_epg_download_xml_gated.ps1",
    [string]$UploadWorker = ".\tools\workers\run_epg_upload_xml_gated.ps1",
    [string]$ImportWorker = ".\tools\workers\run_epg_db_import_upsert_gated.ps1",
    [string]$DownloadScript = ".\local\epg\01_download_epg_xml.ps1",
    [string]$UploadScript = ".\local\epg\02_upload_epg_xml_to_automated.ps1",
    [string]$LocalEpgPath = "C:\miratv_ingest\export\epg.xml",
    [int]$ImportLimit = 19000,
    [int]$MaxImportRuns = 20,
    [switch]$SkipDownload,
    [switch]$SkipUpload,
    [switch]$NoResetImport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}

cd $RepoRoot

try {
    if (-not $SkipDownload) {
        pwsh -NoProfile -ExecutionPolicy Bypass `
          -File $DownloadWorker `
          -Environment $Environment `
          -DownloadScript $DownloadScript `
          -LocalEpgPath $LocalEpgPath `
          -RepoRoot $RepoRoot

        if ($LASTEXITCODE -ne 0) { throw "download worker failed with exit code $LASTEXITCODE" }
    }
    else {
        Write-Host "[orchestrator] Download skipped."
    }

    if (-not $SkipUpload) {
        pwsh -NoProfile -ExecutionPolicy Bypass `
          -File $UploadWorker `
          -Environment $Environment `
          -UploadScript $UploadScript `
          -LocalEpgPath $LocalEpgPath `
          -RepoRoot $RepoRoot

        if ($LASTEXITCODE -ne 0) { throw "upload worker failed with exit code $LASTEXITCODE" }
    }
    else {
        Write-Host "[orchestrator] Upload skipped."
    }

    $importArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ImportWorker,
        "-Environment", $Environment,
        "-RepoRoot", $RepoRoot,
        "-ImportLimit", "$ImportLimit",
        "-MaxImportRuns", "$MaxImportRuns"
    )

    if ($NoResetImport) {
        $importArgs += "-NoReset"
    }

    & pwsh @importArgs
    if ($LASTEXITCODE -ne 0) { throw "import worker failed with exit code $LASTEXITCODE" }

    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
