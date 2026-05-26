$ftpUser = "automated"
$ftpPass = "=tS8nA4yb8]~"
$local   = "C:\miratv_ingest\export\epg.xml"

$paths = @(
    "/epg.xml",
    "epg.xml",
    "/incoming/epg.xml",
    "incoming/epg.xml",
    "/public_ftp/incoming/epg.xml",
    "public_ftp/incoming/epg.xml"
)

foreach ($remote in $paths) {
    Write-Host "Trying $remote"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Credentials = New-Object System.Net.NetworkCredential($ftpUser, $ftpPass)
        $wc.UploadFile("ftp://miratv.club/$remote".Replace("//","/").Replace("ftp:/","ftp://"), $local)
        $wc.Dispose()

        Write-Host "SUCCESS: $remote" -ForegroundColor Green
        break
    }
    catch {
        Write-Host "FAILED: $remote => $($_.Exception.InnerException.Message)" -ForegroundColor Red
    }
}