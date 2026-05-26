#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)]
    [string]$Sql,

    [string]$DatabaseName = "lake_knowledge",

    [string[]]$Params = @(),

    [switch]$PassThruEnvelope,

    [string]$UserQuestion = "",

    [string]$RulesPath = "",

    [switch]$BuildOllamaPayload,

    [string]$OllamaModel = "llama3.1",

    [int]$MaxEvidenceRows = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

function New-QueryError {
    param(
        [string]$Message,
        [object]$RawResponse = $null
    )

    [PSCustomObject]@{
        PSTypeName  = 'MiraTV.QueryError'
        Ok          = $false
        Error       = $Message
        RawResponse = $RawResponse
        Rows        = @()
    }
}

function Test-IsScalarLike {
    param([object]$Value)

    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return $true }
    if ($Value -is [ValueType]) { return $true }
    return $false
}

function Test-LooksLikeRowCollection {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if (-not ($Value -is [System.Collections.IEnumerable])) { return $false }

    $items = @($Value)
    if ($items.Count -eq 0) { return $true }

    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if (Test-IsScalarLike -Value $item) {
            return $false
        }
    }

    return $true
}

function Test-IsStatusOnlyRow {
    param([object]$Row)

    if ($null -eq $Row) { return $true }

    $propNames = @($Row.PSObject.Properties.Name)
    if ($propNames.Count -eq 0) { return $false }

    $statusProps = @('affected', 'ok', 'status', 'message', 'rowcount', 'rows_affected')
    $nonStatus = @($propNames | Where-Object { $_ -notin $statusProps })

    return ($nonStatus.Count -eq 0)
}

function Get-FirstMeaningfulRows {
    param([object]$Response)

    if ($null -eq $Response) {
        return @()
    }

    foreach ($name in @('rows','Rows','data','Data','result','Result')) {
        if ($Response.PSObject.Properties.Name -contains $name) {
            $candidate = $Response.$name
            if (Test-LooksLikeRowCollection -Value $candidate) {
                $rows = @($candidate)
                if ($rows.Count -eq 0) { return @() }
                if (-not (Test-IsStatusOnlyRow -Row $rows[0])) {
                    return $rows
                }
            }
        }
    }

    foreach ($name in @('tables','Tables','resultSets','ResultSets','sets','Sets')) {
        if ($Response.PSObject.Properties.Name -contains $name) {
            foreach ($set in @($Response.$name)) {
                if (Test-LooksLikeRowCollection -Value $set) {
                    $rows = @($set)
                    if ($rows.Count -eq 0) { continue }
                    if (-not (Test-IsStatusOnlyRow -Row $rows[0])) {
                        return $rows
                    }
                }
            }
        }
    }

    foreach ($prop in $Response.PSObject.Properties) {
        $value = $prop.Value
        if (Test-LooksLikeRowCollection -Value $value) {
            $rows = @($value)
            if ($rows.Count -eq 0) { continue }
            if (-not (Test-IsStatusOnlyRow -Row $rows[0])) {
                return $rows
            }
        }
    }

    if (Test-LooksLikeRowCollection -Value $Response) {
        $rows = @($Response)
        if ($rows.Count -gt 0 -and -not (Test-IsStatusOnlyRow -Row $rows[0])) {
            return $rows
        }
    }

    foreach ($name in @('rows','Rows','data','Data','result','Result')) {
        if ($Response.PSObject.Properties.Name -contains $name) {
            return @($Response.$name)
        }
    }

    if (Test-LooksLikeRowCollection -Value $Response) {
        return @($Response)
    }

    return @($Response)
}

function Get-DefaultRulesPath {
    $candidates = @(
        (Join-Path -Path (Get-Location) -ChildPath "pcde_reasoning_rules.yaml"),
        (Join-Path -Path (Get-Location) -ChildPath "dashboard\pcde_reasoning_rules.yaml"),
        (Join-Path -Path $PSScriptRoot -ChildPath "pcde_reasoning_rules.yaml"),
        (Join-Path -Path $PSScriptRoot -ChildPath "..\pcde_reasoning_rules.yaml"),
        "C:\miratv_ingest\pcde_reasoning_rules.yaml",
        "C:\miratv_ingest\dashboard\pcde_reasoning_rules.yaml",
        "/mnt/data/pcde_reasoning_rules.yaml"
    )

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

function Import-ReasoningRules {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-DefaultRulesPath
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "No YAML rules file found. Provide -RulesPath."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "RulesPath not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $raw) {
        throw "RulesPath read returned null: $Path"
    }

    $raw = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "RulesPath is empty: $Path"
    }

    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }

    if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
        $rules = $raw | ConvertFrom-Yaml
    }
    else {
        $psYaml = Get-Module -ListAvailable -Name powershell-yaml
        if (-not $psYaml) {
            throw "ConvertFrom-Yaml is not available and powershell-yaml is not installed."
        }

        Import-Module powershell-yaml -ErrorAction Stop | Out-Null
        $rules = ConvertFrom-Yaml -Yaml $raw
    }

    if ($null -eq $rules) {
        throw "Failed to parse YAML rules file: $Path"
    }

    return $rules
}

function Get-SafeString {
    param([object]$Value)

    if ($null -eq $Value) { return "" }
    return [string]$Value
}

function Test-RegexMatchAny {
    param(
        [string]$Text,
        [object]$RegexList
    )

    $items = @($RegexList)
    foreach ($pattern in $items) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) { continue }
        if ($Text -match [string]$pattern) {
            return $true
        }
    }
    return $false
}

function Test-StartsWithAny {
    param(
        [string]$Text,
        [object]$Prefixes
    )

    $items = @($Prefixes)
    foreach ($prefix in $items) {
        $p = Get-SafeString $prefix
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Text.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-ContainsMatchCount {
    param(
        [string]$Text,
        [object]$Needles
    )

    $count = 0
    $items = @($Needles)
    foreach ($needle in $items) {
        $n = Get-SafeString $needle
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if ($Text.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $count++
        }
    }
    return $count
}

function Get-WordCount {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    return @(($Text -split '\s+' | Where-Object { $_ -ne '' })).Count
}

function Get-QueryTypeFromRules {
    param(
        [string]$Question,
        [object]$Rules
    )

    $text = (Get-SafeString $Question).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [PSCustomObject]@{
            Name = Get-SafeString $Rules.system.default_query_type
            ArbiterMode = "general_resolution"
            MatchedBy = "default"
        }
    }

    $preferredOrder = @()
    if ($Rules.routing_rules.if_multiple_query_types_match.prefer_in_order) {
        $preferredOrder = @($Rules.routing_rules.if_multiple_query_types_match.prefer_in_order)
    }

    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($prop in $Rules.query_types.PSObject.Properties) {
        $name = $prop.Name
        $qt = $prop.Value
        $matched = $false
        $matchedBy = ""

        if ($qt.triggers.default -eq $true) {
            continue
        }

        if ($qt.triggers.regex) {
            if (Test-RegexMatchAny -Text $text -RegexList $qt.triggers.regex) {
                $matched = $true
                $matchedBy = "regex"
            }
        }

        if (-not $matched -and $qt.triggers.starts_with) {
            if (Test-StartsWithAny -Text $text -Prefixes $qt.triggers.starts_with) {
                $matched = $true
                $matchedBy = "starts_with"
            }
        }

        if (-not $matched -and $qt.triggers.contains) {
            $containsCount = Get-ContainsMatchCount -Text $text -Needles $qt.triggers.contains
            if ($containsCount -gt 0) {
                $matched = $true
                $matchedBy = "contains"
            }
        }

        if ($matched -and $qt.triggers.max_terms) {
            $wordCount = Get-WordCount -Text $text
            if ($wordCount -gt [int]$qt.triggers.max_terms) {
                $matched = $false
                $matchedBy = ""
            }
        }

        if ($matched) {
            $matches.Add([PSCustomObject]@{
                Name = $name
                ArbiterMode = Get-SafeString $qt.arbiter_mode
                MatchedBy = $matchedBy
            })
        }
    }

    if ($matches.Count -eq 0) {
        $defaultType = Get-SafeString $Rules.system.default_query_type
        if ([string]::IsNullOrWhiteSpace($defaultType)) {
            $defaultType = "general"
        }

        $arbiterMode = "general_resolution"
        if ($Rules.query_types.$defaultType) {
            $arbiterMode = Get-SafeString $Rules.query_types.$defaultType.arbiter_mode
        }

        return [PSCustomObject]@{
            Name = $defaultType
            ArbiterMode = $arbiterMode
            MatchedBy = "default"
        }
    }

    foreach ($preferred in $preferredOrder) {
        $pick = $matches | Where-Object { $_.Name -eq $preferred } | Select-Object -First 1
        if ($pick) { return $pick }
    }

    return $matches[0]
}

function Get-EvidenceRowsForPrompt {
    param(
        [object[]]$Rows,
        [int]$MaxRows = 8
    )

    if ($null -eq $Rows) { return @() }
    if ($MaxRows -le 0) { return @() }

    $selected = @($Rows | Select-Object -First $MaxRows)

    $rank = 0
    $result = foreach ($row in $selected) {
        $rank++
        [PSCustomObject]@{
            rank = $rank
            source_db = Get-SafeString $row.source_db
            source_table = Get-SafeString $row.source_table
            source_column = Get-SafeString $row.source_column
            record_id = Get-SafeString $row.record_id
            memory_domain = Get-SafeString $row.memory_domain
            evidence_class = Get-SafeString $row.evidence_class
            exact_hit = $row.exact_hit
            core_hit = $row.core_hit
            token_match_count = $row.token_match_count
            source_weight = $row.source_weight
            query_type_bonus = $row.query_type_bonus
            relevance_score = $row.relevance_score
            preview_text = Get-SafeString $row.preview_text
        }
    }

    return @($result)
}

function Convert-EvidenceRowsToText {
    param(
        [object[]]$EvidenceRows
    )

    if ($null -eq $EvidenceRows -or $EvidenceRows.Count -eq 0) {
        return "No evidence rows were returned."
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($row in $EvidenceRows) {
        $lines.Add("[$($row.rank)] class=$($row.evidence_class); score=$($row.relevance_score); source=$($row.source_table); domain=$($row.memory_domain); preview=$($row.preview_text)")
    }

    return ($lines -join [Environment]::NewLine)
}

function Build-SystemPromptFromRules {
    param(
        [object]$Rules,
        [string]$QueryType,
        [string]$Question
    )

    $parts = New-Object System.Collections.Generic.List[string]

    if ($Rules.prompt_contract.enabled -eq $true) {
        $parts.Add((Get-SafeString $Rules.prompt_contract.system_preamble).Trim())

        if ($Rules.prompt_contract.evidence_rules) {
            $parts.Add("Evidence Rules:")
            foreach ($rule in @($Rules.prompt_contract.evidence_rules)) {
                $parts.Add("- $rule")
            }
        }

        if ($Rules.prompt_contract.reasoning_steps) {
            $parts.Add("Reasoning Steps:")
            foreach ($step in @($Rules.prompt_contract.reasoning_steps)) {
                $parts.Add("- $step")
            }
        }
    }

    if ($Rules.evidence_interpretation.enabled -eq $true) {
        $parts.Add("Evidence Interpretation:")
        if ($Rules.evidence_interpretation.ranking.treat_higher_relevance_as_stronger -eq $true) {
            $parts.Add("- Higher relevance_score means stronger evidence.")
        }
        if ($Rules.evidence_interpretation.ranking.review_top_results_first -eq $true) {
            $parts.Add("- Review top-ranked evidence first.")
        }
        if ($Rules.evidence_interpretation.evidence_class_handling.relational) {
            $parts.Add("- Relational evidence is authoritative when directly relevant.")
        }
        if ($Rules.evidence_interpretation.evidence_class_handling.vector) {
            $parts.Add("- Vector evidence is contextual and supportive, not a replacement for direct relational evidence.")
        }
        if ($Rules.evidence_interpretation.verbosity_control.avoid_selecting_answers_based_on_length -eq $true) {
            $parts.Add("- Do not prefer a row because it is longer or more descriptive.")
        }
    }

    if ($Rules.arbiter.must_answer_original_question -eq $true) {
        $parts.Add("You must answer the original user question.")
    }
    if ($Rules.arbiter.must_prefer_system_specific_meaning -eq $true) {
        $parts.Add("Prefer system-specific meanings over external/general meanings when memory evidence exists.")
    }
    if ($Rules.arbiter.must_ignore_low_signal_rows_when_stronger_exist -eq $true) {
        $parts.Add("Ignore lower-signal rows when stronger evidence already supports the answer.")
    }

    if (-not [string]::IsNullOrWhiteSpace($QueryType)) {
        $parts.Add("Detected query type: $QueryType")
    }

    return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine)
}

function Build-UserPromptFromRules {
    param(
        [object]$Rules,
        [string]$Question,
        [object[]]$EvidenceRows
    )

    $topRelational = @($EvidenceRows | Where-Object { $_.evidence_class -eq 'relational' }).Count
    $topVector = @($EvidenceRows | Where-Object { $_.evidence_class -eq 'vector' }).Count

    $outputFields = @("direct_answer","supporting_evidence_summary","confidence_note")
    if ($Rules.prompt_contract.output_shape.fields) {
        $outputFields = @($Rules.prompt_contract.output_shape.fields)
    }

    $evidenceText = Convert-EvidenceRowsToText -EvidenceRows $EvidenceRows

    @"
Question:
$Question

Top evidence quality summary:
- Evidence rows included: $($EvidenceRows.Count)
- Relational evidence present: $(if ($topRelational -gt 0) { 'yes' } else { 'no' })
- Vector evidence present: $(if ($topVector -gt 0) { 'yes' } else { 'no' })
- Results preserve SQL order: yes

Evidence:
$evidenceText

Return JSON with these fields:
$($outputFields -join ', ')
"@.Trim()
}

function Build-OllamaPayload {
    param(
        [string]$Question,
        [object]$Rules,
        [object[]]$Rows,
        [string]$Model = "llama3.1",
        [int]$MaxRows = 8
    )

    $queryTypeInfo = Get-QueryTypeFromRules -Question $Question -Rules $Rules
    $evidenceRows = Get-EvidenceRowsForPrompt -Rows $Rows -MaxRows $MaxRows

    $systemPrompt = Build-SystemPromptFromRules `
        -Rules $Rules `
        -QueryType $queryTypeInfo.Name `
        -Question $Question

    $userPrompt = Build-UserPromptFromRules `
        -Rules $Rules `
        -Question $Question `
        -EvidenceRows $evidenceRows

    $relationalEvidence = @($evidenceRows | Where-Object { $_.evidence_class -eq 'relational' })
    $vectorEvidence = @($evidenceRows | Where-Object { $_.evidence_class -eq 'vector' })

    return [PSCustomObject]@{
        model = $Model
        query_type = $queryTypeInfo.Name
        arbiter_mode = $queryTypeInfo.ArbiterMode
        matched_by = $queryTypeInfo.MatchedBy
        system_prompt = $systemPrompt
        user_prompt = $userPrompt
        evidence = $evidenceRows
        relational_evidence = $relationalEvidence
        vector_evidence = $vectorEvidence
        messages = @(
            @{
                role = "system"
                content = $systemPrompt
            },
            @{
                role = "user"
                content = $userPrompt
            }
        )
    }
}

try {
    Write-Verbose "Executing on [$DatabaseName]"
    Write-Verbose "SQL: $Sql"

    $bodyObject = @{
        token  = $token
        db 	= $DatabaseName
        sql    = $Sql
        params = @($Params)
    }

    $bodyJson = $bodyObject | ConvertTo-Json -Depth 20 -Compress

    $response = Invoke-RestMethod `
        -Uri $endpoint `
        -Method Post `
        -Body $bodyJson `
        -ContentType "application/json"

    $rows = @(Get-FirstMeaningfulRows -Response $response)

    $envelope = [PSCustomObject]@{
        PSTypeName = 'MiraTV.QueryResult'
        Ok         = $true
        Error      = $null
        RowCount   = $rows.Count
        Rows       = $rows
        Raw        = $response
    }

    if ($BuildOllamaPayload) {
        if ([string]::IsNullOrWhiteSpace($UserQuestion)) {
            throw "BuildOllamaPayload requires -UserQuestion."
        }

        $rules = Import-ReasoningRules -Path $RulesPath
        $ollamaPayload = Build-OllamaPayload `
            -Question $UserQuestion `
            -Rules $rules `
            -Rows $rows `
            -Model $OllamaModel `
            -MaxRows $MaxEvidenceRows

        $envelope | Add-Member -MemberType NoteProperty -Name RulesPath -Value $(if ([string]::IsNullOrWhiteSpace($RulesPath)) { Get-DefaultRulesPath } else { $RulesPath })
        $envelope | Add-Member -MemberType NoteProperty -Name OllamaPayload -Value $ollamaPayload
        $envelope | Add-Member -MemberType NoteProperty -Name QueryType -Value $ollamaPayload.query_type
        $envelope | Add-Member -MemberType NoteProperty -Name ArbiterMode -Value $ollamaPayload.arbiter_mode
    }

    if ($PassThruEnvelope) {
        $envelope
    }
    else {
        if ($BuildOllamaPayload) {
            $envelope.OllamaPayload
        }
        else {
            $envelope.Rows
        }
    }
}
catch {
    $rawResponse = $null

    try {
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                $rawResponse = $reader.ReadToEnd()
                $reader.Dispose()
            }
        }
    }
    catch {
    }

    $errorEnvelope = New-QueryError -Message $_.Exception.Message -RawResponse $rawResponse

    if ($PassThruEnvelope) {
        $errorEnvelope
    }
    else {
        throw "Query failed: $($errorEnvelope.Error)"
    }
}