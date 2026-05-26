param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "get_behavior_rules",
        "get_governance_rules",
        "get_control_flags",
        "get_all_rules",
        "save_runtime_metadata",
        "run_sql"
    )]
    [string]$Action,

    [string]$BaseUrl = "https://miratv.club/_workers/api/series/dog_open_proc.php",
    [string]$Token   = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY",
    [string]$DbName  = "xpdgxfsp_inhibitor_govenor_matrix",

    [string]$Sql = "",
    [string]$Version = "",
    [string]$RuntimeHash = "",
    [string]$SourceSnapshot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-BgcTransport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlText,

        [object[]]$Params = @()
    )

    $body = @{
        token  = $Token
        db     = $DbName
        sql    = $SqlText
        params = $Params
    } | ConvertTo-Json -Depth 6

    try {
        $response = Invoke-RestMethod `
            -Uri $BaseUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body $body
    }
    catch {
        throw "BGC transport call failed. $($_.Exception.Message)"
    }

    if ($null -eq $response) {
        throw "BGC transport returned no response."
    }

    $propNames = @($response.PSObject.Properties.Name)

    $hasErrorProp   = $propNames -contains 'error'
    $hasMessageProp = $propNames -contains 'message'

    if ($hasErrorProp -and -not [string]::IsNullOrWhiteSpace([string]$response.error)) {
        $msg = [string]$response.error

        if ($hasMessageProp -and -not [string]::IsNullOrWhiteSpace([string]$response.message)) {
            $msg = "$msg :: $($response.message)"
        }

        throw "BGC transport returned an error. $msg"
    }

    return $response
}

function Invoke-BgcSql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlText,

        [object[]]$Params = @()
    )

    $response = Invoke-BgcTransport -SqlText $SqlText -Params $Params
    $propNames = @($response.PSObject.Properties.Name)

    if ($propNames -contains 'rows') {
        return @($response.rows)
    }

    if ($propNames -contains 'affected') {
        return [pscustomobject]@{
            success       = $true
            affected_rows = [int]$response.affected
        }
    }

    if ($propNames -contains 'rowsets') {
        return @($response.rowsets)
    }

    return $response
}

function Get-BgcBehaviorRules {
    $sql = @"
SELECT
    behavior_id,
    section_name,
    subsection_name,
    behavior_key,
    behavior_value,
    value_type,
    enabled,
    environment,
    changed_by,
    changed_at
FROM bgc_behavior_rules
WHERE enabled = 1
ORDER BY
    section_name ASC,
    subsection_name ASC,
    behavior_key ASC;
"@

    return @(Invoke-BgcSql -SqlText $sql)
}

function Get-BgcGovernanceRules {
    $sql = @"
SELECT
    governance_id,
    rule_code,
    rule_name,
    rule_description,
    togaf_phase,
    rule_type,
    severity,
    applies_to,
    enabled,
    version,
    runtime_state,
    runtime_scope,
    runtime_effect,
    source_rule_id,
    changed_by,
    changed_at
FROM bgc_governance_rules
WHERE enabled = 1
ORDER BY governance_id ASC;
"@

    return @(Invoke-BgcSql -SqlText $sql)
}
function Get-BgcControlFlags {
    $sql = @"
SELECT
    control_id,
    section_name,
    subsection_name,
    flag_key,
    flag_value,
    value_type,
    enabled,
    environment,
    source_setting_id,
    changed_by,
    changed_at
FROM bgc_control_flags
WHERE enabled = 1
ORDER BY
    section_name ASC,
    subsection_name ASC,
    flag_key ASC;
"@

    return @(Invoke-BgcSql -SqlText $sql)
}
function Get-BgcRuleSet {
    return [pscustomobject]@{
        source       = "database"
        generated_at = Get-Date
        behavior     = @(Get-BgcBehaviorRules)
        governance   = @(Get-BgcGovernanceRules)
        control      = @(Get-BgcControlFlags)
    }
}

function Save-BgcRuntimeMetadata {
    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw "Version is required for save_runtime_metadata."
    }

    if ([string]::IsNullOrWhiteSpace($RuntimeHash)) {
        throw "RuntimeHash is required for save_runtime_metadata."
    }

    $escapedVersion  = $Version.Replace("'", "''")
    $escapedHash     = $RuntimeHash.Replace("'", "''")
    $escapedSnapshot = $SourceSnapshot.Replace("'", "''")

    $sql = @"
INSERT INTO bgc_runtime_metadata
(
    runtime_version,
    runtime_hash,
    generated_at,
    source_snapshot
)
VALUES
(
    '$escapedVersion',
    '$escapedHash',
    NOW(),
    '$escapedSnapshot'
);
"@

    return Invoke-BgcSql -SqlText $sql
}

try {
    switch ($Action) {
        "get_behavior_rules"    { Get-BgcBehaviorRules; break }
        "get_governance_rules"  { Get-BgcGovernanceRules; break }
        "get_control_flags"     { Get-BgcControlFlags; break }
        "get_all_rules"         { Get-BgcRuleSet; break }
        "save_runtime_metadata" { Save-BgcRuntimeMetadata; break }
        "run_sql" {
            if ([string]::IsNullOrWhiteSpace($Sql)) {
                throw "Sql is required for run_sql."
            }
            Invoke-BgcSql -SqlText $Sql
            break
        }
        default {
            throw "Unsupported action: $Action"
        }
    }
}
catch {
    throw "Query_BGC.ps1 failed during action [$Action]. $($_.Exception.Message)"
}