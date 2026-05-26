Set-StrictMode -Version Latest

$OPS_DIR  = "C:\miratv_ingest\ops_spool"
$LAKE_DIR = "C:\miratv_ingest\lake_spool"
$IGM_DIR  = "C:\miratv_ingest\igm_spool"

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function NowIso {
    (Get-Date).ToString("o")
}

function Flatten-Fields {
    param([hashtable]$Fields)

    if (-not $Fields -or $Fields.Count -eq 0) {
        return "-"
    }

    return ($Fields.GetEnumerator() |
        ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ";"
}

function Write-Line {
    param(
        [string]$Dir,
        [string]$Prefix,
        [string]$Line
    )

    Ensure-Dir $Dir
    $date = (Get-Date).ToString("yyyyMMdd")
    $file = Join-Path $Dir "${Prefix}_${date}.log"
    Add-Content -Path $file -Value $Line -Encoding UTF8
}

function Emit-Ops {
    param(
        [string]$Event,
        [string]$Worker,
        [string]$Stage,
        [int]$SeriesId = 0,
        [hashtable]$Fields = @{}
    )

    $flat = Flatten-Fields $Fields
    Write-Line $OPS_DIR "ops_events" "$(NowIso) | OPS | event=$Event | worker=$Worker | stage=$Stage | series_id=$SeriesId | $flat"
}

function Emit-Lake {
    param(
        [string]$Signal,
        [string]$Worker,
        [string]$Stage,
        [int]$SeriesId = 0,
        [hashtable]$Fields = @{}
    )

    $flat = Flatten-Fields $Fields
    Write-Line $LAKE_DIR "lake_events" "$(NowIso) | LAKE | signal=$Signal | worker=$Worker | stage=$Stage | series_id=$SeriesId | $flat"
}

function Emit-IGM {
    param(
        [string]$CanonState,
        [string]$Worker,
        [string]$Stage,
        [int]$SeriesId = 0,
        [hashtable]$Fields = @{}
    )

    $flat = Flatten-Fields $Fields
    Write-Line $IGM_DIR "igm_events" "$(NowIso) | IGM | state=$CanonState | worker=$Worker | stage=$Stage | series_id=$SeriesId | $flat"
}

Export-ModuleMember -Function *
