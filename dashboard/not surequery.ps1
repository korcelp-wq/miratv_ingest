param(
    [string]$sql
)

$YamlPaths = @(
    "C:\miratv_ingest\pcde_reasoning_rules.yaml",
    "C:\miratv_ingest\dashboard\pcde_reasoning_rules.yaml"
)

$rules = $null

foreach ($path in $YamlPaths) {
    if (Test-Path $path) {
        try {
            $raw = Get-Content $path -Raw
            if ($raw) {
                $rules = $raw | ConvertFrom-Yaml
                Write-Host "[OK] Loaded rules from $path"
                break
            }
        }
        catch {
            Write-Warning "[WARN] Failed loading $path"
        }
    }
}

if (-not $rules) {
    Write-Warning "[WARN] No reasoning rules loaded"
}

# Continue with your existing SQL execution logic unchanged