function Ask-AI {
    param([string]$Question)

    # Initialize ALL variables at the start to prevent undefined errors
    $routingPlan = $null
    $routingPlan = $null
    $reasoningRules = $null
    $judgementRules = $null
    $longTermSearch = $null
    $memoryResult = $null
    $memorySource = ""
    $confidence = 0
    $memoryCandidates = @()
    $bestCandidate = $null
    $topCandidateSet = @()
    $searchedMemoryTypes = @()
    $retrievalStrategy = ""
    $queryType = "general"
    $querySignature = "general::freeform"
    $keywords = @()
    $escapedQuestion = ""
    $normalizedQuestion = ""

    if (-not $script:aiSessionId) {
        Write-Host "[WARN] No active session. Starting new session..." -ForegroundColor Yellow
        Start-AISession | Out-Null
    }

    Write-Host "`n? Asking AI: $Question" -ForegroundColor Cyan
    Write-Host "[SEARCH] Extracting keywords and searching memory..." -ForegroundColor Yellow

    $escapedQuestion = $Question -replace "'", "''"
    $keywords = @(Get-Keywords -Text $Question)

    if ($keywords.Count -eq 0) {
        Write-Host "   [WARN] No keywords extracted, using full question" -ForegroundColor Yellow
        $keywords = @((Get-PCDENormalizedQuestion -Question $Question))
    }
    else {
        Write-Host "   ? Keywords: $($keywords -join ', ')" -ForegroundColor Green
    }

    # Load reasoning rules with proper error handling
    try {
        $reasoningRules = Import-PCDEReasoningRules
    }
    catch {
        Write-Host "   [WARN] Could not load reasoning rules YAML. Using fallback routing." -ForegroundColor Yellow
        $reasoningRules = [pscustomobject]@{
            system = [pscustomobject]@{ default_query_type = 'general' }
            debug = [pscustomobject]@{ show_query_type = $false; show_selected_evidence_set = $true }
            candidate_selection = [pscustomobject]@{ max_candidates_sent_to_arbiter = 8 }
            memory_types = [pscustomobject]@{
                procedural = [pscustomobject]@{ label = 'Procedural Memory'; default_priority = 0.90 }
                declarative = [pscustomobject]@{ label = 'Declarative Memory'; default_priority = 0.95 }
                associative = [pscustomobject]@{ label = 'Associative Memory'; default_priority = 0.80 }
                working = [pscustomobject]@{ label = 'Working Memory'; default_priority = 0.75 }
                ai_memory = [pscustomobject]@{ label = 'AI Learning Memory'; default_priority = 0.78 }
            }
        }
        # Initialize routing plan in catch block
        $routingPlan = [pscustomobject]@{
            QueryType = 'general'
            QuerySignature = 'general::freeform'
            PreferredOrder = @('declarative','procedural','associative','ai_memory','working')
            Grounding = $null
            ArbiterMode = 'general_resolution'
            Matches = @()
        }
    }

    # Load judgement rules with proper error handling
    try {
        $judgementRules = Import-PCDEJudgementRules
    }
    catch {
        Write-Host ("   [WARN] Could not load judgement rules YAML: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        $judgementRules = $null
    }

    # Ensure routing plan exists before using it
    if (-not $routingPlan) {
        Write-Host "   [INFO] Creating default routing plan..." -ForegroundColor Yellow
        $routingPlan = Get-PCDERoutingPlan -Question $Question -Rules $reasoningRules
        if (-not $routingPlan) {
            # Ultimate fallback if Get-PCDERoutingPlan also fails
            $routingPlan = [pscustomobject]@{
                QueryType = 'general'
                QuerySignature = 'general::freeform'
                PreferredOrder = @('declarative','procedural','associative','ai_memory','working')
                Grounding = $null
                ArbiterMode = 'general_resolution'
                Matches = @()
            }
        }
    }

    # Apply judgement query type override
    $judgementQueryType = Resolve-PCDEJudgementQueryType -Question $Question -CurrentQueryType $routingPlan.QueryType -JudgementRules $judgementRules
    if (-not [string]::IsNullOrWhiteSpace($judgementQueryType) -and $judgementQueryType -ne $routingPlan.QueryType) {
        Write-Host ("   [JUDGE] Query type override: {0} -> {1}" -f $routingPlan.QueryType, $judgementQueryType) -ForegroundColor Yellow
        $routingPlan.QueryType = $judgementQueryType
        $routingPlan.QuerySignature = Get-PCDEQuerySignature -Question $Question -QueryType $judgementQueryType
    }

    # Safely access debug property
    $showQueryType = $false
    if ($reasoningRules -and $reasoningRules.debug -and $null -ne $reasoningRules.debug.show_query_type) {
        $showQueryType = $reasoningRules.debug.show_query_type
    }
    if ($showQueryType -eq $true) {
        Write-Host ("   ? Query Type: {0}" -f $routingPlan.QueryType) -ForegroundColor Yellow
    }

    $normalizedQuestion = Get-PCDENormalizedQuestion -Question $Question
    $queryType = $routingPlan.QueryType
    $querySignature = $routingPlan.QuerySignature
    $retrievalStrategy = ($routingPlan.PreferredOrder -join " -> ")

    # Search through memory types
    foreach ($memoryType in @($routingPlan.PreferredOrder)) {
        $searchedMemoryTypes += $memoryType
        $label = Convert-PCDEMemoryNameToLabel -MemoryName $memoryType -Rules $reasoningRules
        $memoryIcon = switch ($memoryType) {
            'procedural' { '[PROC]' }
            'declarative' { '[DECL]' }
            'associative' { '[ASSOC]' }
            'working' { '[WORK]' }
            'ai_memory' { '[AI]' }
            default { '?' }
        }
        Write-Host ("   {0} Searching {1}..." -f $memoryIcon, $label) -ForegroundColor Cyan

        try {
            $rows = Invoke-PCDEMemorySearchByType -MemoryType $memoryType -Question $Question -Keywords $keywords -SessionId $script:aiSessionId -Rules $reasoningRules
            if ($rows -and @($rows).Count -gt 0) {
                Write-Host ("   [OK] Found in {0} ({1} rows)" -f $label, @($rows).Count) -ForegroundColor Green
                Show-MemoryRowsPreview -Rows @($rows) -Kind $memoryType -MaxLines 3
                $defaultConfidence = 0.70
                if ($reasoningRules -and $reasoningRules.memory_types -and $reasoningRules.memory_types.$memoryType -and $null -ne $reasoningRules.memory_types.$memoryType.default_priority) {
                    $defaultConfidence = [double]$reasoningRules.memory_types.$memoryType.default_priority
                }
                $candidate = New-MemoryCandidate -Source $memoryType -Label $label -Rows $rows -DefaultConfidence $defaultConfidence
                if ($candidate) { $memoryCandidates += $candidate }
            } else {
                Write-Host ("   [NONE] No results in {0}" -f $label) -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host ("   [ERR] {0} failed: {1}" -f $label, $_.Exception.Message) -ForegroundColor Red
        }
    }

    # Process memory candidates if found
    if ($memoryCandidates.Count -gt 0) {
        try {
            $memoryCandidates = @((Set-PCDECandidateScoresFromRules -Candidates $memoryCandidates -Rules $reasoningRules) | Sort-Object -Property Score, Confidence, Count -Descending)
            $memoryCandidates = @(Apply-PCDEJudgementDominanceToCandidates -Candidates $memoryCandidates -QueryType $routingPlan.QueryType -JudgementRules $judgementRules)
            $bestCandidate = $memoryCandidates | Select-Object -First 1
            $topCandidateSet = @(Get-TopCandidateSet -Candidates $memoryCandidates -MaxCandidates 3)
            $memoryResult = @(Get-BlendedEvidenceRows -Candidates $memoryCandidates -MaxCandidates 3 -MaxRowsPerCandidate 5)
            $memorySource = Get-EvidenceSourceTag -Candidates $topCandidateSet -DefaultSource $(if ($bestCandidate) { $bestCandidate.Source } else { 'none' })
            $confidence = Get-EvidenceConfidence -Candidates $topCandidateSet

            $showSelectedEvidenceSet = $true
            if ($reasoningRules -and $reasoningRules.debug -and $null -ne $reasoningRules.debug.show_selected_evidence_set) {
                $showSelectedEvidenceSet = $reasoningRules.debug.show_selected_evidence_set
            }
            if ($showSelectedEvidenceSet -ne $false) {
                Write-Host ("   [TOP] Evidence sets: {0}" -f (Get-EvidenceSourceSummary -Candidates $topCandidateSet -MaxCandidates 5)) -ForegroundColor Magenta
            }
        }
        catch {
            Write-Host ("   [ERR] Error processing memory candidates: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    # Check for procedure availability if no results
    if ((-not $memoryResult -or @($memoryResult).Count -eq 0) -and ($Question -match "procedures?" -or $Question -match "what (procedures|services) (do you have|are available)")) {
        Write-Host "   [PROC] Checking for available procedures in database..." -ForegroundColor Cyan

        $procedureCountSql = "SELECT COUNT(*) as count FROM pcde_procedure_registry WHERE active = 1 OR active IS NULL"
        $procedureCount = Safe-SqlQuery -Sql $procedureCountSql -Context "Procedure Count"

        if ($procedureCount -and $procedureCount[0].count -gt 0) {
            $procedureListSql = @"
SELECT procedure_name, procedure_type, domain, description
FROM pcde_procedure_registry
WHERE active = 1 OR active IS NULL
ORDER BY procedure_name
LIMIT 15
"@
            $procedureList = Safe-SqlQuery -Sql $procedureListSql -Context "Procedure List"

            if ($procedureList) {
                Write-Host "   [OK] Built synthetic procedure candidate" -ForegroundColor Green
                $memoryCandidates += [pscustomobject]@{
                    Source = 'synthetic_procedures'
                    Label = 'Available Procedure List'
                    Rows = @($procedureList)
                    Confidence = 0.95
                    Score = 0.93
                    Count = @($procedureList).Count
                }

                try {
                    $memoryCandidates = @(Apply-PCDEJudgementDominanceToCandidates -Candidates @($memoryCandidates | Sort-Object -Property Score, Confidence, Count -Descending) -QueryType $routingPlan.QueryType -JudgementRules $judgementRules)
                    $bestCandidate = $memoryCandidates | Select-Object -First 1
                    $topCandidateSet = @(Get-TopCandidateSet -Candidates $memoryCandidates -MaxCandidates 3)
                    $memoryResult = @(Get-BlendedEvidenceRows -Candidates $memoryCandidates -MaxCandidates 3 -MaxRowsPerCandidate 5)
                    $memorySource = Get-EvidenceSourceTag -Candidates $topCandidateSet -DefaultSource $(if ($bestCandidate) { $bestCandidate.Source } else { 'synthetic_procedures' })
                    $confidence = Get-EvidenceConfidence -Candidates $topCandidateSet
                }
                catch {
                    Write-Host ("   [ERR] Error processing synthetic procedures: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
        }
    }

    # Pass1 decision with error handling
    $pass1 = $null
    try {
        $pass1 = Invoke-PCDEPass1Decision `
            -Question $Question `
            -QueryType $queryType `
            -Candidates $memoryCandidates `
            -GroundingRules $routingPlan.Grounding `
            -ArbiterMode $routingPlan.ArbiterMode
    }
    catch {
        Write-Host ("   [WARN] Pass1 decision failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        $pass1 = [pscustomobject]@{
            sufficient = $false
            needs_long_term_recall = ($memoryCandidates.Count -eq 0)
            confidence = 0.0
            recall_terms = @($Question)
        }
    }

    # Judgement decision with error handling
    $judgementDecision = $null
    try {
        $judgementDecision = Get-PCDEJudgementDecision `
            -Question $Question `
            -QueryType $queryType `
            -Candidates $memoryCandidates `
            -Keywords $keywords `
            -Pass1 $pass1 `
            -JudgementRules $judgementRules
    }
    catch {
        Write-Host ("   [WARN] Judgement decision failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        $judgementDecision = [pscustomobject]@{
            QueryType = $queryType
            DominantEvidence = 'relational'
            NeedsRecallOverride = $false
            RecallTerms = @()
            Qualification = 'answer_without_qualification'
            EvidenceSufficiency = 'unknown'
        }
    }

    # Apply judgement override if needed
    if ($judgementDecision -and $judgementDecision.NeedsRecallOverride -eq $true) {
        $existingRecallTerms = @($judgementDecision.RecallTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($existingRecallTerms.Count -eq 0 -and $null -ne $pass1) {
            try { $existingRecallTerms = @($pass1.recall_terms) } catch { $existingRecallTerms = @() }
        }
        if ($existingRecallTerms.Count -eq 0) {
            $existingRecallTerms = @($Question)
        }

        $pass1 = [pscustomobject]@{
            sufficient = $false
            needs_long_term_recall = $true
            confidence = if ($null -ne $pass1 -and $null -ne $pass1.confidence) { $pass1.confidence } else { 0.9 }
            recall_terms = $existingRecallTerms
        }
    }

    # Acronym definition override
    if (
        $queryType -eq 'acronym_definition' -or
        ($queryType -eq 'definition' -and $Question -match '^\s*what\s+is\s+[A-Za-z]{2,10}\??\s*$')
    ) {
        Write-Host "   [OVERRIDE] Acronym definition -> forcing long-term recall" -ForegroundColor Yellow

        $existingRecallTerms = @()
        if ($null -ne $pass1) {
            try { $existingRecallTerms = @($pass1.recall_terms) } catch { $existingRecallTerms = @() }
        }
        if ($existingRecallTerms.Count -eq 0) {
            $existingRecallTerms = @($Question)
        }

        $pass1 = [pscustomobject]@{
            sufficient = $false
            needs_long_term_recall = $true
            confidence = 1.0
            recall_terms = $existingRecallTerms
        }
    }

    if ($pass1) {
        Write-Host ("   [AI] Pass1 -> sufficient={0} recall={1}" -f $pass1.sufficient, $pass1.needs_long_term_recall) -ForegroundColor Cyan
    }

    # Long-term recall if needed
    if ($pass1 -and $pass1.needs_long_term_recall -eq $true) {
        $recallTerms = @($keywords | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($recallTerms.Count -eq 0) {
            try { $recallTerms = @($pass1.recall_terms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { $recallTerms = @() }
        }
        if ($recallTerms.Count -eq 0) {
            $recallTerms = @($Question.Trim())
        }

        $longTermSearch = ($recallTerms -join " ")
        $longTermSearch = $longTermSearch.Trim()
        if ([string]::IsNullOrWhiteSpace($longTermSearch)) {
            $longTermSearch = $Question.Trim()
        }
        Write-Host ("   [RECALL] Long-term recall: {0}" -f $longTermSearch) -ForegroundColor Yellow

        $longTermRows = @()
        try {
            $longTermRows = @(Invoke-PCDELongTermRecall -SearchTerm $longTermSearch -QueryType $queryType -MaxRowsPerTarget 25)
        }
        catch {
            Write-Host ("   [ERR] Long-term recall failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }

        if ($longTermRows.Count -gt 0) {
            Write-Host ("   [OK] Long-term recall returned {0} rows" -f $longTermRows.Count) -ForegroundColor Green
            Show-MemoryRowsPreview -Rows @($longTermRows) -Kind 'long_term' -MaxLines 5

            try {
                $splitLongTerm = Split-PCDELongTermRowsByEvidenceClass -Rows @($longTermRows)

                if (@($splitLongTerm.relational).Count -gt 0) {
                    $memoryCandidates += [pscustomobject]@{
                        Source = 'long_term_relational'
                        Label = 'Long Term Memory (Relational)'
                        Rows = @($splitLongTerm.relational)
                        Confidence = 0.90
                        Score = 0.95
                        Count = @($splitLongTerm.relational).Count
                        EvidenceClass = 'relational'
                    }
                }

                if (@($splitLongTerm.vector).Count -gt 0) {
                    $memoryCandidates += [pscustomobject]@{
                        Source = 'long_term_vector'
                        Label = 'Long Term Memory (Vector)'
                        Rows = @($splitLongTerm.vector)
                        Confidence = 0.72
                        Score = 0.78
                        Count = @($splitLongTerm.vector).Count
                        EvidenceClass = 'vector'
                    }
                }

                if ((@($splitLongTerm.relational).Count + @($splitLongTerm.vector).Count) -eq 0) {
                    $memoryCandidates += [pscustomobject]@{
                        Source = 'long_term'
                        Label = 'Long Term Memory'
                        Rows = @($longTermRows)
                        Confidence = 0.89
                        Score = 0.95
                        Count = @($longTermRows).Count
                        EvidenceClass = 'relational'
                    }
                }

                $memoryCandidates = @(Apply-PCDEJudgementDominanceToCandidates -Candidates @($memoryCandidates | Sort-Object -Property Score, Confidence, Count -Descending) -QueryType $queryType -JudgementRules $judgementRules)
                $bestCandidate = $memoryCandidates | Select-Object -First 1
                $topCandidateSet = @(Get-TopCandidateSet -Candidates $memoryCandidates -MaxCandidates 3)
                $memoryResult = @(Get-BlendedEvidenceRows -Candidates $memoryCandidates -MaxCandidates 3 -MaxRowsPerCandidate 5)
                $memorySource = Get-EvidenceSourceTag -Candidates $topCandidateSet -DefaultSource $(if ($bestCandidate) { $bestCandidate.Source } else { 'long_term' })
                $confidence = Get-EvidenceConfidence -Candidates $topCandidateSet

                $showSelectedEvidenceSet = $true
                if ($reasoningRules -and $reasoningRules.debug -and $null -ne $reasoningRules.debug.show_selected_evidence_set) {
                    $showSelectedEvidenceSet = $reasoningRules.debug.show_selected_evidence_set
                }
                if ($showSelectedEvidenceSet -ne $false) {
                    Write-Host ("   [TOP] Reconciled evidence sets: {0}" -f (Get-EvidenceSourceSummary -Candidates $topCandidateSet -MaxCandidates 5)) -ForegroundColor Magenta
                }
            }
            catch {
                Write-Host ("   [ERR] Error processing long-term recall results: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
        }
        else {
            Write-Host "   [NONE] Long-term recall returned no additional rows" -ForegroundColor DarkGray
            Write-Host ("   [LOG] Debug log: {0}" -f (Join-Path $logDir (("master_control_debug_{0}.log" -f (Get-Date -Format "yyyyMMdd"))))) -ForegroundColor DarkYellow
        }
    }

    Write-Host "[OLLAMA] Asking Ollama to evaluate the question against retrieved memory..." -ForegroundColor Yellow
    
    $maxCandidates = 8
    if ($reasoningRules -and $reasoningRules.candidate_selection -and $null -ne $reasoningRules.candidate_selection.max_candidates_sent_to_arbiter) {
        $maxCandidates = $reasoningRules.candidate_selection.max_candidates_sent_to_arbiter
    }
    $arbiterCandidates = @($memoryCandidates | Select-Object -First $maxCandidates)
    
    $arbiterResult = $null
    try {
        $arbiterResult = Invoke-OllamaMemoryArbiter `
            -Question $Question `
            -Candidates $arbiterCandidates `
            -Keywords $keywords `
            -QueryType $queryType `
            -GroundingRules $routingPlan.Grounding `
            -ArbiterMode $routingPlan.ArbiterMode `
            -JudgementContext $judgementDecision
    }
    catch {
        Write-Host ("   [ERR] Ollama arbitration failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $arbiterResult = $null
    }

    if ($arbiterResult) {
        $finalAnswer = [string]$arbiterResult.Answer
        if ([string]::IsNullOrWhiteSpace($finalAnswer) -and $memoryResult) {
            $finalAnswer = Format-MemoryRows -Rows $memoryResult -Kind $(if ([string]::IsNullOrWhiteSpace($memorySource)) { 'multi_source' } else { $memorySource })
        }

        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $escapedAnswer = $finalAnswer -replace "'", "''"

        try {
            Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null
        }
        catch {
            Write-DebugLog -Category 'DB' -Message ("Failed to save to working memory: {0}" -f $_.Exception.Message)
        }

        $evidenceSourceTag = Get-EvidenceSourceTag -Candidates $arbiterCandidates -DefaultSource 'multi_source'
        $sourceTag = if ([string]::IsNullOrWhiteSpace($arbiterResult.SelectedSource)) { "ollama:$evidenceSourceTag" } else { "ollama:$($arbiterResult.SelectedSource)" }

        $selectedEvidence = @(Get-BlendedEvidenceRows -Candidates $arbiterCandidates -MaxCandidates 3 -MaxRowsPerCandidate 5)

        $allEvidence = @()
        foreach ($candidate in @($arbiterCandidates)) {
            if ($candidate.Rows) {
                $allEvidence += @($candidate.Rows | Select-Object -First 5)
            }
        }

        try {
            [void](Write-PCDEArbitrationHistory `
                -Question $Question `
                -QueryType $queryType `
                -ArbiterMode $routingPlan.ArbiterMode `
                -SqlSearchTerm $longTermSearch `
                -ModelName $arbiterResult.Model `
                -AnswerText $finalAnswer `
                -Confidence $arbiterResult.Confidence `
                -Grounded $arbiterResult.Grounded `
                -SelectedEvidence $selectedEvidence `
                -AllEvidence $allEvidence `
                -OutcomeStatus 'provisional' `
                -ConversationId $querySignature `
                -SessionId $script:aiSessionId)
        }
        catch {
            Write-DebugLog -Category 'ARBITRATION' -Message ("Failed to write arbitration history: {0}" -f $_.Exception.Message)
        }

        try {
            [void](Promote-ToProceduralMemory `
                -Question $Question `
                -AnswerText $finalAnswer `
                -Confidence $arbiterResult.Confidence `
                -Grounded $arbiterResult.Grounded `
                -QueryType $queryType `
                -ProcedureType 'learned_workflow' `
                -WhyItExists 'Captured from grounded successful arbitration cycle.')
        }
        catch {
            Write-DebugLog -Category 'PROMOTION' -Message ("Failed to promote to procedural memory: {0}" -f $_.Exception.Message)
        }

        return @{
            answer = $finalAnswer
            source = $sourceTag
            confidence = $arbiterResult.Confidence
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }

    # Fallback when Ollama is unavailable
    if ($memoryResult -and @($memoryResult).Count -gt 0) {
        Write-Host "[WARN] Ollama unavailable. Falling back to highest-scoring retrieved memory." -ForegroundColor Yellow

        $formattedAnswer = Format-MemoryRows -Rows $memoryResult -Kind $(if ([string]::IsNullOrWhiteSpace($memorySource)) { 'multi_source' } else { $memorySource })
        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $escapedAnswer = $formattedAnswer -replace "'", "''"

        try {
            Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null
        }
        catch {
            Write-DebugLog -Category 'DB' -Message ("Failed to save fallback to working memory: {0}" -f $_.Exception.Message)
        }

        $selectedEvidence = @($memoryResult | Select-Object -First 5)

        try {
            [void](Write-PCDEArbitrationHistory `
                -Question $Question `
                -QueryType $queryType `
                -ArbiterMode $routingPlan.ArbiterMode `
                -SqlSearchTerm $longTermSearch `
                -ModelName 'fallback_memory' `
                -AnswerText $formattedAnswer `
                -Confidence $confidence `
                -Grounded $true `
                -SelectedEvidence $selectedEvidence `
                -AllEvidence $selectedEvidence `
                -OutcomeStatus 'provisional' `
                -ConversationId $querySignature `
                -SessionId $script:aiSessionId)
        }
        catch {
            Write-DebugLog -Category 'ARBITRATION' -Message ("Failed to write fallback arbitration history: {0}" -f $_.Exception.Message)
        }

        try {
            [void](Promote-ToProceduralMemory `
                -Question $Question `
                -AnswerText $formattedAnswer `
                -Confidence $confidence `
                -Grounded $true `
                -QueryType $queryType `
                -ProcedureType 'learned_workflow' `
                -WhyItExists 'Captured from successful memory fallback cycle.')
        }
        catch {
            Write-DebugLog -Category 'PROMOTION' -Message ("Failed to promote fallback to procedural memory: {0}" -f $_.Exception.Message)
        }

        return @{
            answer = $formattedAnswer
            source = $memorySource
            confidence = $confidence
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }

    # Ultimate fallback when everything fails
    Write-Host "[OLLAMA] No memory matches and Ollama arbitration unavailable. Using plain Ollama fallback if possible..." -ForegroundColor Yellow

    $model = Get-OllamaModel
    if (-not $model) {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, but no stored memory matched and Ollama was not reachable."
            source = "fallback"
            confidence = 0.5
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }

    $prompt = @"
You are MiraTV AI assistant, specialized in the MiraTV ingest system.

No stored memory candidates matched this question.
Answer the user's question as helpfully as you can, but clearly acknowledge that no stored memory matched.

User question:
$Question
"@

    $body = @{
        model = $model
        prompt = $prompt
        stream = $false
        options = @{ temperature = 0.4 }
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" `
            -Method Post `
            -Body $body `
            -ContentType "application/json"

        $answer = [string]$response.response
        $escapedAnswer = $answer -replace "'", "''"

        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        try {
            Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null
        }
        catch {
            Write-DebugLog -Category 'DB' -Message ("Failed to save ultimate fallback to working memory: {0}" -f $_.Exception.Message)
        }

        try {
            [void](Write-PCDEArbitrationHistory `
                -Question $Question `
                -QueryType $queryType `
                -ArbiterMode 'plain_ollama_fallback' `
                -SqlSearchTerm '' `
                -ModelName $model `
                -AnswerText $answer `
                -Confidence 0.70 `
                -Grounded $false `
                -SelectedEvidence @() `
                -AllEvidence @() `
                -OutcomeStatus 'provisional' `
                -ConversationId $querySignature `
                -SessionId $script:aiSessionId)
        }
        catch {
            Write-DebugLog -Category 'ARBITRATION' -Message ("Failed to write ultimate fallback arbitration history: {0}" -f $_.Exception.Message)
        }

        return @{
            answer = $answer
            source = "ollama"
            confidence = 0.7
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }
    catch {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, but no stored memory matched and Ollama was unavailable."
            source = "fallback"
            confidence = 0.5
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }
}