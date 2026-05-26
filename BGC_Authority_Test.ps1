
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# BGC Authority Test - Standalone External Runtime Proof
# Proves BGC can govern an outside app launch
# ============================================================

$Config = [ordered]@{
    QueryScript        = 'C:\MiraTV\Modules\IMG\BGC\Query_BGC.ps1'
    DatabaseName       = 'xpdgxfsp_inhibitor_govenor_matrix'

    # Governance rule used by this test
    RuleDomain         = 'governance'
    RuleCode           = 'BLOCK_TEST_APP'
    RuleType           = 'constraint'

    # External app to govern
    TestAppPath        = 'notepad.exe'

    # Decision logging toggle
    EnableDecisionLog  = $true
}

$script:StatusLabel      = $null
$script:RuleStateLabel   = $null
$script:LastDecisionBox  = $null
$script:ContextBox       = $null

function Escape-SqlString {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value -replace "'", "''"
}

function Set-Status {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::DarkSlateGray
    )

    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Message
        $script:StatusLabel.ForeColor = $Color
    }
}

function Invoke-BgcAction {
    param(
        [Parameter(Mandatory = $true)] [string]$Action,
        [string]$Sql = ''
    )

    if (-not (Test-Path $Config.QueryScript)) {
        throw "Query script not found: $($Config.QueryScript)"
    }

    $params = @{
        Action = $Action
        DbName = $Config.DatabaseName
    }

    if (-not [string]::IsNullOrWhiteSpace($Sql)) {
        $params.Sql = $Sql
    }

    try {
        return & $Config.QueryScript @params
    }
    catch {
        throw "BGC query failed during [$Action]. $($_.Exception.Message)"
    }
}

function Invoke-BgcNonQuery {
    param([Parameter(Mandatory = $true)][string]$Sql)
    $null = Invoke-BgcAction -Action 'run_sql' -Sql $Sql
    return $true
}

function Ensure-TestRuleExists {
    $ruleCode = Escape-SqlString $Config.RuleCode
    $ruleType = Escape-SqlString $Config.RuleType

    $sql = @"
INSERT INTO bgc_governance_rules
(rule_code, rule_name, rule_type, severity, enabled, rule_description)
VALUES
('$ruleCode', '$ruleCode', '$ruleType', 'hard', 0, 'Standalone authority test rule for external app launch.')
ON DUPLICATE KEY UPDATE
    rule_name = VALUES(rule_name),
    rule_type = VALUES(rule_type),
    rule_description = VALUES(rule_description);
"@

    Invoke-BgcNonQuery -Sql $sql | Out-Null
}

function Get-TestRule {
    $ruleCode = Escape-SqlString $Config.RuleCode
    $sql = @"
SELECT
    rule_code,
    rule_name,
    rule_type,
    severity,
    enabled,
    rule_description
FROM bgc_governance_rules
WHERE rule_code = '$ruleCode'
LIMIT 1;
"@

    $result = Invoke-BgcAction -Action 'run_sql' -Sql $sql

    if ($null -eq $result) { return $null }

    if ($result -is [System.Array]) {
        return ($result | Select-Object -First 1)
    }

    return $result
}

function Is-TestAppBlocked {
    $rule = Get-TestRule
    if ($null -eq $rule) { return $false }

    $enabledValue = [string]$rule.enabled
    return ($enabledValue -eq '1' -or $enabledValue -eq 'true')
}

function Set-TestRuleState {
    param([bool]$Enabled)

    $enabledInt = if ($Enabled) { 1 } else { 0 }
    $ruleCode = Escape-SqlString $Config.RuleCode

    $sql = "UPDATE bgc_governance_rules SET enabled = $enabledInt WHERE rule_code = '$ruleCode';"
    Invoke-BgcNonQuery -Sql $sql | Out-Null
}

function Write-DecisionLog {
    param(
        [string]$Decision,
        [string]$ActionName,
        [string]$OutcomeText,
        [string]$ContextPreview
    )

    if (-not $Config.EnableDecisionLog) { return }

    $decision     = Escape-SqlString $Decision
    $ruleCode     = Escape-SqlString $Config.RuleCode
    $domainName   = Escape-SqlString $Config.RuleDomain
    $targetName   = Escape-SqlString $Config.TestAppPath
    $actionName   = Escape-SqlString $ActionName
    $outcomeText  = Escape-SqlString $OutcomeText
    $contextText  = Escape-SqlString $ContextPreview

    $sql = @"
INSERT INTO bgc_decision_history
(
    decided_at,
    decision_type,
    rule_code,
    severity,
    domain_name,
    target_name,
    action_name,
    outcome_text,
    context_preview,
    runtime_hash,
    notes
)
VALUES
(
    NOW(),
    '$decision',
    '$ruleCode',
    'hard',
    '$domainName',
    '$targetName',
    '$actionName',
    '$outcomeText',
    '$contextText',
    NULL,
    'Standalone authority test'
);
"@

    try {
        Invoke-BgcNonQuery -Sql $sql | Out-Null
    }
    catch {
        # Logging should not kill the proof flow
    }
}

function Refresh-RuleState {
    try {
        Ensure-TestRuleExists

        $blocked = Is-TestAppBlocked
        if ($blocked) {
            $script:RuleStateLabel.Text = "Rule State: BLOCKED (`$Config.RuleCode enabled)"
            $script:RuleStateLabel.ForeColor = [System.Drawing.Color]::Firebrick
        }
        else {
            $script:RuleStateLabel.Text = "Rule State: ALLOWED (`$Config.RuleCode disabled)"
            $script:RuleStateLabel.ForeColor = [System.Drawing.Color]::ForestGreen
        }

        Set-Status "Rule state refreshed." ([System.Drawing.Color]::DarkSlateGray)
    }
    catch {
        Set-Status $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
}

function Set-LastDecision {
    param([string]$Text)
    if ($script:LastDecisionBox) {
        $script:LastDecisionBox.Text = $Text
    }
}

function Launch-GovernedTestApp {
    try {
        Ensure-TestRuleExists

        $blocked = Is-TestAppBlocked
        $context = $script:ContextBox.Text
        if ([string]::IsNullOrWhiteSpace($context)) {
            $context = 'Manual authority test launch'
        }

        if ($blocked) {
            $msg = "BLOCKED: $($Config.TestAppPath) launch denied by BGC rule $($Config.RuleCode)."
            Set-LastDecision $msg
            Write-DecisionLog -Decision 'block' -ActionName 'launch_test_app' -OutcomeText 'blocked' -ContextPreview $context
            Set-Status $msg ([System.Drawing.Color]::Firebrick)
            [System.Windows.Forms.MessageBox]::Show(
                $msg,
                'Governed Launch Result',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        Start-Process $Config.TestAppPath | Out-Null

        $msg = "ALLOWED: $($Config.TestAppPath) launched by governed action."
        Set-LastDecision $msg
        Write-DecisionLog -Decision 'allow' -ActionName 'launch_test_app' -OutcomeText 'launched' -ContextPreview $context
        Set-Status $msg ([System.Drawing.Color]::ForestGreen)
    }
    catch {
        Set-Status $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
}

function Launch-DirectTestApp {
    try {
        Start-Process $Config.TestAppPath | Out-Null
        $msg = "DIRECT LAUNCH: $($Config.TestAppPath) opened without BGC governance check."
        Set-LastDecision $msg
        Set-Status $msg ([System.Drawing.Color]::DarkSlateGray)
    }
    catch {
        Set-Status $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
}

# ============================================================
# FORM
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'BGC Authority Test'
$form.Width = 900
$form.Height = 540
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(245,247,250)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'BGC Authority Test'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(18,15)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = 'Standalone proof that BGC can govern launch of an external application.'
$sub.AutoSize = $true
$sub.ForeColor = [System.Drawing.Color]::DimGray
$sub.Location = New-Object System.Drawing.Point(20,50)
$form.Controls.Add($sub)

$ruleGroup = New-Object System.Windows.Forms.GroupBox
$ruleGroup.Text = 'Governance Rule'
$ruleGroup.Location = New-Object System.Drawing.Point(18,82)
$ruleGroup.Size = New-Object System.Drawing.Size(400,160)
$form.Controls.Add($ruleGroup)

$ruleCodeLabel = New-Object System.Windows.Forms.Label
$ruleCodeLabel.Text = "Rule Code: $($Config.RuleCode)"
$ruleCodeLabel.AutoSize = $true
$ruleCodeLabel.Location = New-Object System.Drawing.Point(18,32)
$ruleGroup.Controls.Add($ruleCodeLabel)

$targetLabel = New-Object System.Windows.Forms.Label
$targetLabel.Text = "Target App: $($Config.TestAppPath)"
$targetLabel.AutoSize = $true
$targetLabel.Location = New-Object System.Drawing.Point(18,58)
$ruleGroup.Controls.Add($targetLabel)

$script:RuleStateLabel = New-Object System.Windows.Forms.Label
$script:RuleStateLabel.Text = 'Rule State: Checking...'
$script:RuleStateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$script:RuleStateLabel.AutoSize = $true
$script:RuleStateLabel.Location = New-Object System.Drawing.Point(18,88)
$ruleGroup.Controls.Add($script:RuleStateLabel)

$allowButton = New-Object System.Windows.Forms.Button
$allowButton.Text = 'Set Rule OFF (Allow)'
$allowButton.Size = New-Object System.Drawing.Size(150,34)
$allowButton.Location = New-Object System.Drawing.Point(18,118)
$ruleGroup.Controls.Add($allowButton)

$blockButton = New-Object System.Windows.Forms.Button
$blockButton.Text = 'Set Rule ON (Block)'
$blockButton.Size = New-Object System.Drawing.Size(150,34)
$blockButton.Location = New-Object System.Drawing.Point(180,118)
$ruleGroup.Controls.Add($blockButton)

$actionGroup = New-Object System.Windows.Forms.GroupBox
$actionGroup.Text = 'Authority Proof Actions'
$actionGroup.Location = New-Object System.Drawing.Point(438,82)
$actionGroup.Size = New-Object System.Drawing.Size(430,160)
$form.Controls.Add($actionGroup)

$checkRuleButton = New-Object System.Windows.Forms.Button
$checkRuleButton.Text = 'Check Rule'
$checkRuleButton.Size = New-Object System.Drawing.Size(120,34)
$checkRuleButton.Location = New-Object System.Drawing.Point(18,32)
$actionGroup.Controls.Add($checkRuleButton)

$governedLaunchButton = New-Object System.Windows.Forms.Button
$governedLaunchButton.Text = 'Launch Governed App'
$governedLaunchButton.Size = New-Object System.Drawing.Size(170,34)
$governedLaunchButton.Location = New-Object System.Drawing.Point(150,32)
$actionGroup.Controls.Add($governedLaunchButton)

$directLaunchButton = New-Object System.Windows.Forms.Button
$directLaunchButton.Text = 'Open Notepad Directly'
$directLaunchButton.Size = New-Object System.Drawing.Size(170,34)
$directLaunchButton.Location = New-Object System.Drawing.Point(18,78)
$actionGroup.Controls.Add($directLaunchButton)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Size = New-Object System.Drawing.Size(120,34)
$refreshButton.Location = New-Object System.Drawing.Point(200,78)
$actionGroup.Controls.Add($refreshButton)

$explainLabel = New-Object System.Windows.Forms.Label
$explainLabel.Text = 'Direct launch proves the app itself is fine. Governed launch proves BGC can allow or block it.'
$explainLabel.AutoSize = $false
$explainLabel.Size = New-Object System.Drawing.Size(390,34)
$explainLabel.Location = New-Object System.Drawing.Point(18,122)
$explainLabel.ForeColor = [System.Drawing.Color]::DimGray
$actionGroup.Controls.Add($explainLabel)

$contextGroup = New-Object System.Windows.Forms.GroupBox
$contextGroup.Text = 'Test Context'
$contextGroup.Location = New-Object System.Drawing.Point(18,258)
$contextGroup.Size = New-Object System.Drawing.Size(850,120)
$form.Controls.Add($contextGroup)

$contextLabel = New-Object System.Windows.Forms.Label
$contextLabel.Text = 'Context for decision log'
$contextLabel.AutoSize = $true
$contextLabel.Location = New-Object System.Drawing.Point(18,30)
$contextGroup.Controls.Add($contextLabel)

$script:ContextBox = New-Object System.Windows.Forms.TextBox
$script:ContextBox.Location = New-Object System.Drawing.Point(18,52)
$script:ContextBox.Size = New-Object System.Drawing.Size(810,25)
$script:ContextBox.Text = 'Authority proof test for external governed app launch'
$contextGroup.Controls.Add($script:ContextBox)

$decisionGroup = New-Object System.Windows.Forms.GroupBox
$decisionGroup.Text = 'Last Decision'
$decisionGroup.Location = New-Object System.Drawing.Point(18,392)
$decisionGroup.Size = New-Object System.Drawing.Size(850,80)
$form.Controls.Add($decisionGroup)

$script:LastDecisionBox = New-Object System.Windows.Forms.TextBox
$script:LastDecisionBox.Location = New-Object System.Drawing.Point(18,30)
$script:LastDecisionBox.Size = New-Object System.Drawing.Size(810,25)
$script:LastDecisionBox.ReadOnly = $true
$decisionGroup.Controls.Add($script:LastDecisionBox)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Ready'
$script:StatusLabel.AutoSize = $false
$script:StatusLabel.Size = New-Object System.Drawing.Size(850,24)
$script:StatusLabel.Location = New-Object System.Drawing.Point(18,482)
$script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($script:StatusLabel)

# ============================================================
# EVENTS
# ============================================================
$allowButton.Add_Click({
    try {
        Ensure-TestRuleExists
        Set-TestRuleState -Enabled $false
        Refresh-RuleState
        Set-LastDecision 'Rule turned OFF. Governed launch should now be allowed.'
        Set-Status 'Rule turned OFF (allow).' ([System.Drawing.Color]::ForestGreen)
    }
    catch {
        Set-Status $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
})

$blockButton.Add_Click({
    try {
        Ensure-TestRuleExists
        Set-TestRuleState -Enabled $true
        Refresh-RuleState
        Set-LastDecision 'Rule turned ON. Governed launch should now be blocked.'
        Set-Status 'Rule turned ON (block).' ([System.Drawing.Color]::Firebrick)
    }
    catch {
        Set-Status $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
})

$checkRuleButton.Add_Click({
    Refresh-RuleState
})

$governedLaunchButton.Add_Click({
    Launch-GovernedTestApp
})

$directLaunchButton.Add_Click({
    Launch-DirectTestApp
})

$refreshButton.Add_Click({
    Refresh-RuleState
})

$form.Add_Shown({
    try {
        Ensure-TestRuleExists
        Refresh-RuleState
        Set-LastDecision 'Ready. Turn rule ON to block governed launch, OFF to allow governed launch.'
        Set-Status 'Authority test ready.' ([System.Drawing.Color]::DarkSlateGray)
    }
    catch {
        Set-Status $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
})

[void]$form.ShowDialog()
```
