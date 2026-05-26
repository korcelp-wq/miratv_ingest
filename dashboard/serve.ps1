# Simple PowerShell HTTP server
$http = [System.Net.HttpListener]::new()
$http.Prefixes.Add("http://localhost:8080/")
$http.Start()
Write-Host "Server running at http://localhost:8080/" -ForegroundColor Green

while ($http.IsListening) {
    $context = $http.GetContext()
    $response = $context.Response
    
    $path = $context.Request.Url.LocalPath
    if ($path -eq "/") { $path = "/index.html" }
    
    $filePath = [System.IO.Path]::Combine($PWD.Path, $path.TrimStart('/'))
    
    if ([System.IO.File]::Exists($filePath)) {
        $content = [System.IO.File]::ReadAllBytes($filePath)
        $response.ContentType = switch ([System.IO.Path]::GetExtension($filePath)) {
            ".html" { "text/html" }
            ".json" { "application/json" }
            ".css" { "text/css" }
            ".js" { "application/javascript" }
            default { "application/octet-stream" }
        }
        $response.OutputStream.Write($content, 0, $content.Length)
    } else {
        $response.StatusCode = 404
    }
    $response.Close()
}