# =========================================================
# MiraTV DB Grinder Upload
# PURPOSE:
#  - Upload files from raw_store_db to FTP
#  - Emit permanent upload telemetry (per file)
#  - One-shot execution
#  - Fail fast on error
# =========================================================

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------
# CONFIG
# ---------------------------------------------------------
$LocalPickupPath = "C:\miratv_ingest\raw_store_db\pickup"
$ProcessedPath   = "C:\miratv_ingest\raw_store_db\processed"

$FtpHost         = "ftp://miratv.club"
$FtpUser         = "automated"
$FtpPass         = "=tS8nA4yb8]~"
$FtpTargetDir    = "/incoming/raw"

$TelemetryUrl    = "https://miratv.club/api/telemetry_upload.php"
$RunId           = $env:RUN_ID
$Source          = "db_grinder_upload"
$Transport       = "ftp"

# ---------------------------------------------------------
# VALIDATE
# ---------------------------------------------------------
if (-not (Test-Path $LocalPickupPath)) {
    throw "Local pickup path does not exist: $LocalPickupPath"
}

if (-not (Test-Path $ProcessedPath)) {
    New-Item -ItemType Directory -Path $ProcessedPath | Out-Null
}

$files = Get-ChildItem -Path $LocalPickupPath -File
if ($files.Count -eq 0) {
    Write-Host "No files to upload."
    exit 0
}

# ---------------------------------------------------------
# UPLOAD LOOP
# ---------------------------------------------------------
foreach ($file in $files) {

    $ftpUri = "$FtpHost$FtpTargetDir/$($file.Name)"
    Write-Host "Uploading $($file.Name) -> $ftpUri"

    $startTime = Get-Date

    try {
        $request = [System.Net.FtpWebRequest]::Create($ftpUri)
        $request.Method      = [System.Net.WebRequestMethods+Ftp]::UploadFile
        $request.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPass)
        $request.UseBinary   = $true
        $request.UsePassive  = $true
        $request.KeepAlive   = $false

        $fileBytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $request.ContentLength = $fileBytes.Length

        $requestStream = $request.GetRequestStream()
        $requestStream.Write($fileBytes, 0, $fileBytes.Length)
        $requestStream.Close()

        $response = $request.GetResponse()
        $response.Close()

        $endTime = Get-Date
        $uploadMs = [int]($endTime - $startTime).TotalMilliseconds

        # -------------------------------------------------
        # TELEMETRY — SUCCESS
        # -------------------------------------------------
        Invoke-RestMethod `
            -Uri $TelemetryUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body (@{
                run_id     = $RunId
                file_name = $file.Name
                file_size = $file.Length
                upload_ms = $uploadMs
                status    = "SUCCESS"
                transport = $Transport
                source    = $Source
            } | ConvertTo-Json)

        # -------------------------------------------------
        # MOVE FILE AFTER SUCCESS
        # -------------------------------------------------
        Move-Item $file.FullName "$ProcessedPath\$($file.Name)" -Force
        Write-Host "✔ Uploaded and archived: $($file.Name)"

    }
    catch {
        $endTime = Get-Date
        $uploadMs = [int]($endTime - $startTime).TotalMilliseconds

        # -------------------------------------------------
        # TELEMETRY — FAILURE
        # -------------------------------------------------
        Invoke-RestMethod `
            -Uri $TelemetryUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body (@{
                run_id     = $RunId
                file_name = $file.Name
                file_size = $file.Length
                upload_ms = $uploadMs
                status    = "FAILURE"
                transport = $Transport
                source    = $Source
            } | ConvertTo-Json)

        Write-Error "❌ Upload failed for $($file.Name): $_"
        throw
    }
}

Write-Host "All uploads completed successfully."
exit 0

