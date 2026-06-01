<#
.SYNOPSIS
    Inspect current provider account context for one MiraTV app account.

.DESCRIPTION
    Read-only worker that asks the MiraTV gateway/backend for the same account context
    the Android app already uses through AccountSession/get_current_user_context.php.

    Default behavior:
      - calls get_current_user_context.php only
      - does NOT call provider/player_api.php
      - does NOT call validate_current_provider_account.php
      - does NOT write DB rows
      - writes redacted runtime reports only

    Optional behavior:
      - pass -IncludeBackendValidation to also call validate_current_provider_account.php
      - this still calls the MiraTV backend endpoint, not provider/player_api directly from this worker
      - all URL/link/query credentials are redacted before report output

    Intended clean-repo location:
      tools\workers\inspect_provider_account_context.ps1
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "inspect_provider_account_context",
    [string]$Component = "provider_account_context",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_PROVIDER_ACCOUNT_CONTEXT_INSPECTION",

    [int]$MacUserId = 6,
    [string]$ProviderLabel = "",
    [string]$GatewayBaseUrl = "https://miratv.club",
    [string]$OutputRoot = "runtime/reports/provider_account_context_inspection",

    [switch]$IncludeBackendValidation,
    [switch]$SkipEndpointCalls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Stage = "init"

function Get-RepoRootLocal {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue
    if ($null -ne $resolved) { return $resolved.Path }
    return (Get-Location).Path
}

function New-RunIdLocal {
    param([string]$Prefix = "provider-account-context-inspection")
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N")
    return "$Prefix-$stamp-$guid"
}

function New-DirectoryLocal {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Test-KillSwitchCompatible {
    param(
        [string]$Name,
        [bool]$DefaultEnabled = $true
    )

    $cmd = Get-Command Test-KillSwitch -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $DefaultEnabled }

    $result = Test-KillSwitch -Name $Name -DefaultEnabled $DefaultEnabled
    if ($result -is [bool]) { return [bool]$result }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "enabled")) {
        return [bool]$result.enabled
    }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "is_enabled")) {
        return [bool]$result.is_enabled
    }

    return $DefaultEnabled
}

function ConvertTo-PlainObjectLocal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [pscustomobject]) {
        $ordered = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $ordered[$prop.Name] = ConvertTo-PlainObjectLocal -Value $prop.Value
        }
        return $ordered
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $ordered[[string]$key] = ConvertTo-PlainObjectLocal -Value $Value[$key]
        }
        return $ordered
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $arr = @()
        foreach ($item in $Value) {
            $arr += ConvertTo-PlainObjectLocal -Value $item
        }
        return $arr
    }

    return $Value
}

function Redact-ScalarLocal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text = [string]$Value

    $text = $text -replace '(?i)(username=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(password=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(token=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(api_key=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(apiKey=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(Authorization:\s*Bearer\s+)[A-Za-z0-9._\-]+', '$1REDACTED'
    $text = $text -replace '(?i)(Bearer\s+)[A-Za-z0-9._\-]+', '$1REDACTED'

    return $text
}

function Redact-ObjectLocal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}

        foreach ($key in $Value.Keys) {
            $k = [string]$key
            $v = $Value[$key]

            if ($k -match '(?i)^password$|password_raw|provider_password|token|secret|api[_-]?key|authorization') {
                $ordered[$k] = "REDACTED"
            }
            elseif ($k -match '(?i)^username$|provider_username') {
                $raw = [string]$v
                $ordered[$k] = if ([string]::IsNullOrWhiteSpace($raw)) { "" } else { "PRESENT_REDACTED" }
            }
            elseif ($k -match '(?i)m3u|url|link|uri|endpoint|payload') {
                if ($v -is [string]) {
                    $ordered[$k] = Redact-ScalarLocal -Value $v
                }
                else {
                    $ordered[$k] = Redact-ObjectLocal -Value $v
                }
            }
            else {
                $ordered[$k] = Redact-ObjectLocal -Value $v
            }
        }

        return $ordered
    }

    if ($Value -is [pscustomobject]) {
        $plain = ConvertTo-PlainObjectLocal -Value $Value
        return Redact-ObjectLocal -Value $plain
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $arr = @()
        foreach ($item in $Value) {
            $arr += Redact-ObjectLocal -Value $item
        }
        return $arr
    }

    if ($Value -is [string]) {
        return Redact-ScalarLocal -Value $Value
    }

    return $Value
}

function Invoke-JsonGetLocal {
    param(
        [string]$Url,
        [int]$TimeoutSec = 30
    )

    $headers = @{
        "Accept" = "application/json"
        "User-Agent" = "MiraTV-MasterControl-ProviderAccountContextInspector/1.1"
    }

    $started = Get-Date

    try {
        $response = Invoke-RestMethod -Method GET -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

        return [pscustomobject]@{
            ok = $true
            skipped = $false
            elapsed_ms = $elapsedMs
            error = ""
            response = $response
        }
    }
    catch {
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

        return [pscustomobject]@{
            ok = $false
            skipped = $false
            elapsed_ms = $elapsedMs
            error = $_.Exception.Message
            response = $null
        }
    }
}

function New-SkippedEndpointResultLocal {
    param([string]$Reason)

    return [pscustomobject]@{
        ok = $false
        skipped = $true
        elapsed_ms = 0
        error = $Reason
        response = $null
    }
}

function Get-ContextFieldLocal {
    param(
        [AllowNull()][object]$Response,
        [string[]]$Path
    )

    $current = $Response

    foreach ($segment in $Path) {
        if ($null -eq $current) { return $null }

        if ($current.PSObject.Properties.Name -contains $segment) {
            $current = $current.$segment
            continue
        }

        return $null
    }

    return $current
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal
$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$startedAt = Get-Date
$signalName = "provider_account_context_inspection_completed"

try {
    $script:Stage = "validate_inputs"

    if ($MacUserId -le 0) {
        throw "MacUserId must be greater than zero."
    }

    $gateway = $GatewayBaseUrl.Trim().TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($gateway)) {
        throw "GatewayBaseUrl is required."
    }

    $provider = $ProviderLabel.Trim()
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = ""
    }

    $script:Stage = "kill_switch"
    if ($loggingAvailable) {
        $killEnabled = Test-KillSwitchCompatible -Name $KillSwitchName -DefaultEnabled $true

        if (-not $killEnabled) {
            Write-JobLog `
                -RunId $script:RunId `
                -JobName $WorkerName `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -EventType "worker_blocked" `
                -Status "blocked" `
                -Data @{
                    event_message = "Provider account context inspection blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                    mac_user_id = $MacUserId
                    provider_label = $provider
                } | Out-Null

            Write-Output "BLOCKED: provider account context inspection blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
            exit 0
        }

        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_started" `
            -Status "started" `
            -Data @{
                event_message = "Provider account context inspection started."
                mac_user_id = $MacUserId
                provider_label = $provider
                gateway_base_url = $gateway
                skip_endpoint_calls = [bool]$SkipEndpointCalls
                include_backend_validation = [bool]$IncludeBackendValidation
            } | Out-Null
    }

    $contextUrl = "$gateway/_workers/ai/api/get_current_user_context.php?mac_user_id=$MacUserId&debug=1"
    $validateUrl = "$gateway/_workers/ai/api/validate_current_provider_account.php?mac_user_id=$MacUserId&debug=1"

    if (-not [string]::IsNullOrWhiteSpace($provider)) {
        $validateUrl = "$validateUrl&provider=$([uri]::EscapeDataString($provider))"
    }

    $contextResult = $null
    $validateResult = $null

    if ($SkipEndpointCalls) {
        $contextResult = New-SkippedEndpointResultLocal -Reason "skipped_by_parameter"
        $validateResult = New-SkippedEndpointResultLocal -Reason "skipped_by_parameter"
    }
    else {
        $script:Stage = "call_get_current_user_context"
        $contextResult = Invoke-JsonGetLocal -Url $contextUrl

        if ($IncludeBackendValidation) {
            $script:Stage = "call_validate_current_provider_account"
            $validateResult = Invoke-JsonGetLocal -Url $validateUrl
        }
        else {
            $validateResult = New-SkippedEndpointResultLocal -Reason "skipped_without_include_backend_validation"
        }
    }

    $script:Stage = "extract_context"

    $contextResponse = $contextResult.response
    $validateResponse = $validateResult.response

    $contextMacUserId = Get-ContextFieldLocal -Response $contextResponse -Path @("context", "mac_user_id")
    $contextProviderLabel = Get-ContextFieldLocal -Response $contextResponse -Path @("context", "provider_label")
    $contextDns = Get-ContextFieldLocal -Response $contextResponse -Path @("context", "dns")
    $contextServerName = Get-ContextFieldLocal -Response $contextResponse -Path @("context", "server_name")
    $contextUsername = Get-ContextFieldLocal -Response $contextResponse -Path @("context", "username")
    $contextStatus = Get-ContextFieldLocal -Response $contextResponse -Path @("context", "status")

    $validateMacUserId = Get-ContextFieldLocal -Response $validateResponse -Path @("context", "mac_user_id")
    if ($null -eq $validateMacUserId) { $validateMacUserId = Get-ContextFieldLocal -Response $validateResponse -Path @("mac_user_id") }

    $validateProviderLabel = Get-ContextFieldLocal -Response $validateResponse -Path @("context", "provider_label")
    if ($null -eq $validateProviderLabel) { $validateProviderLabel = Get-ContextFieldLocal -Response $validateResponse -Path @("provider_label") }

    $validateDns = Get-ContextFieldLocal -Response $validateResponse -Path @("context", "dns")
    if ($null -eq $validateDns) { $validateDns = Get-ContextFieldLocal -Response $validateResponse -Path @("dns") }
    if ($null -eq $validateDns) { $validateDns = Get-ContextFieldLocal -Response $validateResponse -Path @("provider_dns") }

    $validateStatus = Get-ContextFieldLocal -Response $validateResponse -Path @("status")
    if ($null -eq $validateStatus) { $validateStatus = Get-ContextFieldLocal -Response $validateResponse -Path @("context", "status") }

    $contextUsernamePresent = -not [string]::IsNullOrWhiteSpace([string]$contextUsername)

    $resolvedDns = [string]$contextDns
    if ([string]::IsNullOrWhiteSpace($resolvedDns)) {
        $resolvedDns = [string]$validateDns
    }

    $resolvedProvider = [string]$contextProviderLabel
    if ([string]::IsNullOrWhiteSpace($resolvedProvider)) {
        $resolvedProvider = [string]$validateProviderLabel
    }

    $resolvedMacUserId = [string]$contextMacUserId
    if ([string]::IsNullOrWhiteSpace($resolvedMacUserId)) {
        $resolvedMacUserId = [string]$validateMacUserId
    }

    $statusValue = "warning"
    if ($contextResult.ok -and -not [string]::IsNullOrWhiteSpace($resolvedDns)) {
        $statusValue = "pass"
    }
    elseif ($validateResult.ok -and -not [string]::IsNullOrWhiteSpace($resolvedDns)) {
        $statusValue = "pass"
    }

    $script:Stage = "write_reports"

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $summaryJson = Join-Path $outputRootFull "provider_account_context_inspection_summary_$stamp.json"
    $endpointCsv = Join-Path $outputRootFull "provider_account_context_endpoint_summary_$stamp.csv"

    $endpointRows = @(
        [pscustomobject]@{
            endpoint_name = "get_current_user_context"
            url = Redact-ScalarLocal -Value $contextUrl
            ok = [bool]$contextResult.ok
            skipped = [bool]$contextResult.skipped
            elapsed_ms = [int]$contextResult.elapsed_ms
            error = [string]$contextResult.error
            mac_user_id = [string]$contextMacUserId
            provider_label = [string]$contextProviderLabel
            dns_present = -not [string]::IsNullOrWhiteSpace([string]$contextDns)
            server_name_present = -not [string]::IsNullOrWhiteSpace([string]$contextServerName)
            username_present = $contextUsernamePresent
            status = [string]$contextStatus
        },
        [pscustomobject]@{
            endpoint_name = "validate_current_provider_account"
            url = Redact-ScalarLocal -Value $validateUrl
            ok = [bool]$validateResult.ok
            skipped = [bool]$validateResult.skipped
            elapsed_ms = [int]$validateResult.elapsed_ms
            error = [string]$validateResult.error
            mac_user_id = [string]$validateMacUserId
            provider_label = [string]$validateProviderLabel
            dns_present = -not [string]::IsNullOrWhiteSpace([string]$validateDns)
            server_name_present = $false
            username_present = $false
            status = [string]$validateStatus
        }
    )

    $endpointRows | Export-Csv -LiteralPath $endpointCsv -NoTypeInformation -Encoding UTF8

    $contextPlain = ConvertTo-PlainObjectLocal -Value $contextResponse
    $validatePlain = ConvertTo-PlainObjectLocal -Value $validateResponse

    $summary = [pscustomobject]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        read_only = $true
        provider_calls = $false
        db_writes = $false
        include_backend_validation = [bool]$IncludeBackendValidation
        mac_user_id_requested = $MacUserId
        provider_label_requested = $provider
        gateway_base_url = $gateway
        get_current_user_context_ok = [bool]$contextResult.ok
        get_current_user_context_skipped = [bool]$contextResult.skipped
        validate_current_provider_account_ok = [bool]$validateResult.ok
        validate_current_provider_account_skipped = [bool]$validateResult.skipped
        resolved_mac_user_id = $resolvedMacUserId
        resolved_provider_label = $resolvedProvider
        resolved_dns_present = -not [string]::IsNullOrWhiteSpace($resolvedDns)
        resolved_dns = $resolvedDns
        context_username_present = $contextUsernamePresent
        context_status = [string]$contextStatus
        overall_status = $statusValue
        endpoint_csv = $endpointCsv
        redacted_get_current_user_context = Redact-ObjectLocal -Value $contextPlain
        redacted_validate_current_provider_account = Redact-ObjectLocal -Value $validatePlain
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    if ($loggingAvailable) {
        $script:Stage = "emit_success"

        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status $statusValue `
            -Data @{
                event_message = "Provider account context inspection completed."
                read_only = $true
                provider_calls = $false
                mac_user_id = $MacUserId
                provider_label = $provider
                include_backend_validation = [bool]$IncludeBackendValidation
                resolved_dns_present = $summary.resolved_dns_present
                get_current_user_context_ok = $summary.get_current_user_context_ok
                validate_current_provider_account_ok = $summary.validate_current_provider_account_ok
                validate_current_provider_account_skipped = $summary.validate_current_provider_account_skipped
                duration_ms = $durationMs
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue $statusValue `
            -Status $statusValue `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/inspect_provider_account_context.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.account.context.inspection"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                read_only = $true
                provider_calls = $false
                mac_user_id = $MacUserId
                provider_label = $provider
                include_backend_validation = [bool]$IncludeBackendValidation
                resolved_dns_present = $summary.resolved_dns_present
                validate_current_provider_account_skipped = $summary.validate_current_provider_account_skipped
                endpoint_csv = $endpointCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: provider account context inspection completed. status={0} read_only=True provider_calls=False mac_user_id={1} provider_label=""{2}"" resolved_dns_present={3} backend_validation_skipped={4} output_root=""{5}"" run_id={6}" -f `
        $statusValue, `
        $MacUserId, `
        $provider, `
        $summary.resolved_dns_present, `
        $summary.validate_current_provider_account_skipped, `
        $outputRootFull, `
        $script:RunId)

    Write-Output ("FILES: endpoint_csv=""{0}"" summary_json=""{1}""" -f $endpointCsv, $summaryJson)

    if ($statusValue -eq "fail") {
        exit 1
    }
}
catch {
    $errorMessage = "stage=$script:Stage; error=$($_.Exception.Message)"

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_failed" `
            -Status "failed" `
            -Data @{
                event_message = "Provider account context inspection failed."
                error = $errorMessage
                mac_user_id = $MacUserId
                provider_label = $ProviderLabel
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue "fail" `
            -Status "fail" `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/inspect_provider_account_context.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.account.context.inspection"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: provider account context inspection failed. run_id=$script:RunId $errorMessage"
    exit 1
}


