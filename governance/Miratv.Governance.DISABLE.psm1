# Miratv.Governance.psm1
Set-StrictMode -Version Latest

function Get-ContractPath {
    param([string]$Path = "C:\miratv_ingest\governance\runtime_contract.yaml")
    return $Path
}

function Load-Contract {
    param([string]$Path = $(Get-ContractPath))
    if (-not (Test-Path $Path)) {
        throw "Runtime contract not found: $Path"
    }

    # Requires PowerShell 7+ for ConvertFrom-Yaml
    try {
        $yaml = Get-Content $Path -Raw -Encoding UTF8
        $contract = $yaml | ConvertFrom-Yaml
        return $contract
    } catch {
        throw "Failed to parse contract YAML. Ensure PS7+ or provide JSON contract. Error: $($_.Exception.Message)"
    }
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function New-Event {
    param(
        [Parameter(Mandatory)] [string]$Tag,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Component = "unknown",
        [string]$Stage = "unknown",
        [int]$SeriesId = 0,
        [hashtable]$Fields = @{}
    )

    $evt = [ordered]@{
        ts        = (Get-Date).ToString("o")
        tag       = $Tag
        component = $Component
        stage     = $Stage
        series_id = $SeriesId
        message   = $Message
        fields    = $Fields
    }

    return ($evt | ConvertTo-Json -Depth 8 -Compress)
}

function Emit-Event {
    param(
        [Parameter(Mandatory)] $Contract,
        [Parameter(Mandatory)] [string] $EventJson
    )

    $dir = $Contract.logging.local_spool_dir
    Ensure-Dir $dir

    $date = (Get-Date).ToString("yyyyMMdd")
    $file = Join-Path $dir "$($Contract.logging.file_prefix)_$date.jsonl"

    Add-Content -Path $file -Value $EventJson -Encoding UTF8
}

function Emit-RuleAttestation {
    param(
        [Parameter(Mandatory)] $Contract,
        [Parameter(Mandatory)] [string] $RuleId,
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [string] $Stage,
        [int] $SeriesId = 0,
        [string] $Effect = ""
    )

    $rule = $Contract.rules.$RuleId

    # PS5.1-safe null handling
    $ruleEffect = $Effect
    if ($rule -and $rule.PSObject.Properties.Name -contains "effect" -and $rule.effect) {
        $ruleEffect = $rule.effect
    }

    $fields = @{
        rule_id     = $RuleId
        rule_state  = $rule.state
        rule_scope  = $rule.scope
        rule_effect = $ruleEffect
    }

    $json = New-Event `
        -Tag "RULE" `
        -Message "Rule attested: $RuleId" `
        -Component $Component `
        -Stage $Stage `
        -SeriesId $SeriesId `
        -Fields $fields

    Emit-Event -Contract $Contract -EventJson $json
}

function Emit-Metric {
    param(
        [Parameter(Mandatory)] $Contract,
        [Parameter(Mandatory)] [string] $Signal,
        [Parameter(Mandatory)] [string] $Domain,
        [int] $Magnitude = 1,
        [string] $Confidence = "low",
        [string] $Component = "unknown",
        [string] $Stage = "unknown",
        [int] $SeriesId = 0
    )

    $fields = @{
        signal     = $Signal
        domain     = $Domain
        magnitude  = $Magnitude
        confidence = $Confidence
    }

    $json = New-Event `
        -Tag "STATE" `
        -Message "Metric signal emitted" `
        -Component $Component `
        -Stage $Stage `
        -SeriesId $SeriesId `
        -Fields $fields

    Emit-Event -Contract $Contract -EventJson $json
}

Export-ModuleMember -Function *
