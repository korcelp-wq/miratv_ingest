Set-StrictMode -Version Latest

$BASE = "C:\miratv_ingest"
$OPS  = Join-Path $BASE "ops_spool"
$LAKE = Join-Path $BASE "lake_spool"
$IGM  = Join-Path $BASE "igm_spool"

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function NowIso {
    (Get-Date).ToString("o")
}

function Write-Line {
    param(
        [string]$Dir,
        [string]$Prefix,
        [string]$Line
    )
    Ensure-Dir $Dir
    $date = (Get-Date).ToString("yyyyMMdd")
    Add-Content -Encoding UTF8 -Path (Join-Path $Dir "${Prefix}_${date}.log") -Value $Line
}

function Emit-Ops {
    param(
        [string]$Event,
        [string]$Component,
        [hashtable]$Fields = @{}
    )
    $fieldStr = ($Fields.Keys | ForEach-Object { "$_=$($Fields[$_])" }) -join " | "
    Write-Line $OPS "ops" "$(NowIso) | $Component | $Event | $fieldStr"
}

function Emit-Lake {
    param(
        [string]$Signal,
        [string]$Component,
        [hashtable]$Fields = @{}
    )
    $fieldStr = ($Fields.Keys | ForEach-Object { "$_=$($Fields[$_])" }) -join " | "
    Write-Line $LAKE "lake" "$(NowIso) | $Component | $Signal | $fieldStr"
}

function Emit-IGM {
    param(
        [string]$Canon,
        [string]$Component,
        [hashtable]$Fields = @{}
    )
    $fieldStr = ($Fields.Keys | ForEach-Object { "$_=$($Fields[$_])" }) -join " | "
    Write-Line $IGM "igm" "$(NowIso) | $Component | $Canon | $fieldStr"
}

Export-ModuleMember -Function Emit-Ops, Emit-Lake, Emit-IGM
