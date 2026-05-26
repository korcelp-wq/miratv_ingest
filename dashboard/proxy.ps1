# C:\miratv_ingest\dashboard\proxy.ps1 - FIXED with inline token
$http = [System.Net.HttpListener]::new()
$http.Prefixes.Add("http://localhost:8888/")
$http.Start()
Write-Host "✅ Proxy running at http://localhost:8888/" -ForegroundColor Green
Write-Host "Token will be added as query parameter" -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop" -ForegroundColor Yellow

# Your token
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

while ($http.IsListening) {
    $context = $http.GetContext()
    
    try {
        if ($context.Request.Url.LocalPath -eq "/cvi") {
            # Read the incoming request body
            $reader = New-Object System.IO.StreamReader $context.Request.InputStream
            $bodyJson = $reader.ReadToEnd()
            Write-Host "➡️ Received request" -ForegroundColor Gray
            
            # Parse the body to get db, sql, params
            $body = $bodyJson | ConvertFrom-Json
            
            # Build URL with token inline
            $url = "https://miratv.club/_workers/api/series/dog_open.php?token=$token"
            
            # Prepare the body for forwarding (without token)
            $forwardBody = @{
                db = $body.db
                sql = $body.sql
                params = $body.params
            } | ConvertTo-Json
            
            Write-Host "🔗 Forwarding to: $url" -ForegroundColor Gray
            
            # Forward to dog_open.php with token in URL
            $response = Invoke-RestMethod -Uri $url `
                -Method Post `
                -Body $forwardBody `
                -ContentType "application/json" `
                -ErrorAction Stop
            
            # Convert response to JSON and send back
            $responseJson = $response | ConvertTo-Json -Depth 10
            $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseJson)
            
            $context.Response.ContentType = "application/json"
            $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
            Write-Host "✅ Response sent" -ForegroundColor Green
        } else {
            # Serve static files
            $path = $context.Request.Url.LocalPath
            if ($path -eq "/") { $path = "/index.html" }
            $filePath = [System.IO.Path]::Combine($PWD.Path, $path.TrimStart('/'))
            
            Write-Host "📁 Serving: $path" -ForegroundColor Gray
            
            if ([System.IO.File]::Exists($filePath)) {
                $content = [System.IO.File]::ReadAllBytes($filePath)
                $context.Response.ContentType = switch ([System.IO.Path]::GetExtension($filePath)) {
                    ".html" { "text/html" }
                    ".json" { "application/json" }
                    ".css" { "text/css" }
                    ".js" { "application/javascript" }
                    default { "application/octet-stream" }
                }
                $context.Response.OutputStream.Write($content, 0, $content.Length)
            } else {
                $context.Response.StatusCode = 404
                $errorBytes = [System.Text.Encoding]::UTF8.GetBytes("File not found: $path")
                $context.Response.OutputStream.Write($errorBytes, 0, $errorBytes.Length)
            }
        }
    } catch {
        Write-Host "❌ Error: $_" -ForegroundColor Red
        $context.Response.StatusCode = 500
        $errorResponse = @{ error = $_.ToString() } | ConvertTo-Json
        $errorBytes = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
        $context.Response.ContentType = "application/json"
        $context.Response.OutputStream.Write($errorBytes, 0, $errorBytes.Length)
    }
    
    $context.Response.Close()
}