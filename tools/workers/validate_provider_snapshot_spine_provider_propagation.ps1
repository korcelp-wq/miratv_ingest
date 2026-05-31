param(
    [string]$SpinePath = ".\tools\workers\run_provider_snapshot_spine.ps1"
)

$ErrorActionPreference = "Stop"

$FullPath = Resolve-Path -LiteralPath $SpinePath
$Text = Get-Content -LiteralPath $FullPath -Raw

$errors = @()

# 1. Syntax parse
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    $errors += "PowerShell syntax errors found."
    $parseErrors | ForEach-Object { $errors += ("  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
}

# 2. Must not contain the failed old variable
if ($Text -match '\$EffectiveProviderLabel') {
    $errors += "Found deprecated failed-patch variable: `$EffectiveProviderLabel"
}

# 3. Required propagation helper
if ($Text -notmatch 'function\s+Get-ResolvedProviderLabelFromChildOutputLocal') {
    $errors += "Missing helper: Get-ResolvedProviderLabelFromChildOutputLocal"
}

# 4. Required child provider variable
if ($Text -notmatch '\$ProviderLabelForChildren\s*=\s*\$ProviderLabel') {
    $errors += "Missing initialization: `$ProviderLabelForChildren = `$ProviderLabel"
}

# 5. Initialization must happen before first usage
$initIndex = $Text.IndexOf('$ProviderLabelForChildren = $ProviderLabel')
$useIndex = $Text.IndexOf('$ProviderLabelForChildren')

if ($initIndex -lt 0) {
    $errors += "Cannot find ProviderLabelForChildren initialization."
}
elseif ($useIndex -ge 0 -and $useIndex -lt $initIndex) {
    $errors += "ProviderLabelForChildren is used before initialization."
}

# 6. Child workers must receive ProviderLabelForChildren
if ($Text -notmatch '-ProviderLabel\s+\$ProviderLabelForChildren') {
    $errors += "Child worker pass-through is not using `$ProviderLabelForChildren."
}

# 7. Must extract resolved_provider_label
if ($Text -notmatch 'resolved_provider_label') {
    $errors += "No resolved_provider_label extraction/reference found."
}

# 8. Must read summary_json from child output
if ($Text -notmatch 'summary_json="\(\[\^"\]\+\)"' -and $Text -notmatch 'summary_json') {
    $errors += "No summary_json extraction/reference found."
}

if ($errors.Count -gt 0) {
    Write-Host "VALIDATION: fail" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}

Write-Host "VALIDATION: pass" -ForegroundColor Green
exit 0
