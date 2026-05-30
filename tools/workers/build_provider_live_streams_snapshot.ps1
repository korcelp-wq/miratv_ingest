<#
.SYNOPSIS
    Build a governed Live streams provider snapshot for one MiraTV account.

.DESCRIPTION
    Provider inventory snapshot worker for Live streams. Larger than category snapshots, but still read-only/no DB import.

    Flow:
      1. Resolve current account/provider context from MiraTV backend:
           get_current_user_context.php
      2. Use the resolved provider DNS + credential-bearing M3U link when available.
      3. Call provider player_api.php?action=get_live_streams.
      4. Save raw snapshot under runtime/provider_snapshots/live_streams.
      5. Compute SHA256 hash.
      6. Compare against latest prior snapshot for same mac_user_id/provider_label.
      7. Emit governed signal and runtime reports.

    This worker:
      - DOES call provider player_api.php for get_live_streams only.
      - DOES NOT import to database.
      - DOES NOT call get_live_streams.
      - DOES NOT call VOD/Series/EPG.
      - DOES NOT print credentials.
      - DOES NOT commit credentials to config.
      - DOES NOT use old hardcoded spine domains.

    Intended clean-repo location:
      tools\workers\build_provider_live_streams_snapshot.ps1
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "build_provider_live_streams_snapshot",
    [string]$Component = "provider_live_streams_snapshot",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_PROVIDER_LIVE_STREAMS_SNAPSHOT",

    [int]$MacUserId = 6,
    [string]$ProviderLabel = "",
    [string]$GatewayBaseUrl = "https://miratv.club",

    [string]$SnapshotRoot = "runtime/provider_snapshots/live_streams",
    [string]$OutputRoot = "runtime/reports/provider_live_streams_snapshot",

    [switch]$SkipBackendCredentialResolution,

    [int]$TimeoutSec = 45
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
    param([string]$Prefix = "provider-live-streams-snapshot")
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

function Redact-ScalarLocal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }

    $text = [string]$Value
    $text = $text -replace '(?i)(username=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(password=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(token=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(api_key=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(apiKey=)[^&''"\s]+', '$1REDACTED'
    $text = $text -replace '(?i)(Bearer\s+)[A-Za-z0-9._\-]+', '$1REDACTED'
    return $text
}

function Invoke-JsonGetLocal {
    param(
        [string]$Url,
        [int]$TimeoutSec = 45,
        [string]$UserAgent = "MiraTV-MasterControl-LiveStreamSnapshot/1.0"
    )

    $headers = @{
        "Accept" = "application/json"
        "User-Agent" = $UserAgent
    }

    $started = Get-Date

    try {
        $response = Invoke-RestMethod -Method GET -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

        return [pscustomobject]@{
            ok = $true
            elapsed_ms = $elapsedMs
            error = ""
            response = $response
        }
    }
    catch {
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

        return [pscustomobject]@{
            ok = $false
            elapsed_ms = $elapsedMs
            error = $_.Exception.Message
            response = $null
        }
    }
}

function Invoke-RawGetLocal {
    param(
        [string]$Url,
        [int]$TimeoutSec = 45
    )

    $headers = @{
        "Accept" = "application/json"
        "User-Agent" = "MiraTV-MasterControl-LiveStreamSnapshot/1.0"
    }

    $started = Get-Date

    try {
        $response = Invoke-WebRequest -Method GET -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

        return [pscustomobject]@{
            ok = $true
            elapsed_ms = $elapsedMs
            status_code = [int]$response.StatusCode
            error = ""
            body = [string]$response.Content
        }
    }
    catch {
        $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
        $statusCode = 0
        $body = ""

        if ($null -ne $_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = 0
            }
        }

        return [pscustomobject]@{
            ok = $false
            elapsed_ms = $elapsedMs
            status_code = $statusCode
            error = $_.Exception.Message
            body = $body
        }
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

function Get-QueryParamLocal {
    param(
        [string]$Url,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return "" }

    try {
        $uri = [System.Uri]$Url
        $query = $uri.Query.TrimStart("?")
        foreach ($pair in $query.Split("&")) {
            if ([string]::IsNullOrWhiteSpace($pair)) { continue }

            $parts = $pair.Split("=", 2)
            if ($parts.Count -lt 2) { continue }

            $key = [System.Uri]::UnescapeDataString($parts[0])
            if ($key -ieq $Name) {
                return [System.Uri]::UnescapeDataString($parts[1])
            }
        }
    }
    catch {
        return ""
    }

    return ""
}

function Get-M3uLinkFromContextLocal {
    param([AllowNull()][object]$ContextResponse)

    $m3uLink = Get-ContextFieldLocal -Response $ContextResponse -Path @("context", "m3u_link")
    if (-not [string]::IsNullOrWhiteSpace([string]$m3uLink)) {
        return [string]$m3uLink
    }

    $sessionM3u = Get-ContextFieldLocal -Response $ContextResponse -Path @("session_payload", "m3u_link")
    if (-not [string]::IsNullOrWhiteSpace([string]$sessionM3u)) {
        return [string]$sessionM3u
    }

    return ""
}

function Get-ProviderCredentialsFromContextLocal {
    param([AllowNull()][object]$ContextResponse)

    $dns = [string](Get-ContextFieldLocal -Response $ContextResponse -Path @("context", "dns"))
    if ([string]::IsNullOrWhiteSpace($dns)) {
        $dns = [string](Get-ContextFieldLocal -Response $ContextResponse -Path @("context", "server_name"))
    }

    $username = [string](Get-ContextFieldLocal -Response $ContextResponse -Path @("context", "username"))
    $password = [string](Get-ContextFieldLocal -Response $ContextResponse -Path @("context", "password"))

    $m3uLink = Get-M3uLinkFromContextLocal -ContextResponse $ContextResponse
    if (-not [string]::IsNullOrWhiteSpace($m3uLink)) {
        if ([string]::IsNullOrWhiteSpace($username)) {
            $username = Get-QueryParamLocal -Url $m3uLink -Name "username"
        }

        if ([string]::IsNullOrWhiteSpace($password)) {
            $password = Get-QueryParamLocal -Url $m3uLink -Name "password"
        }

        if ([string]::IsNullOrWhiteSpace($dns)) {
            try {
                $uri = [System.Uri]$m3uLink
                $dns = $uri.Host
                if ($uri.Port -gt 0 -and $uri.Port -ne 80 -and $uri.Port -ne 443) {
                    $dns = "$dns`:$($uri.Port)"
                }
            }
            catch {
                $dns = ""
            }
        }
    }

    [pscustomobject]@{
        dns = $dns
        username = $username
        password = $password
        username_present = -not [string]::IsNullOrWhiteSpace($username)
        password_present = -not [string]::IsNullOrWhiteSpace($password)
        m3u_link_present = -not [string]::IsNullOrWhiteSpace($m3uLink)
    }
}

function New-ProviderApiUrlLocal {
    param(
        [string]$Dns,
        [string]$Username,
        [string]$Password,
        [string]$Action
    )

    $providerHost = $Dns.Trim()
    $providerHost = $providerHost -replace '^https?://', ''
    $providerHost = $providerHost.TrimEnd('/')

    if ($providerHost -notmatch ':\d+$') {
        $providerHost = "$providerHost`:8080"
    }

    $u = [System.Uri]::EscapeDataString($Username)
    $p = [System.Uri]::EscapeDataString($Password)
    $a = [System.Uri]::EscapeDataString($Action)

    return "http://$providerHost/player_api.php?username=$u&password=$p&action=$a"
}

function Get-Sha256OfTextLocal {
    param([string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-JsonCountSafeLocal {
    param([string]$Text)

    try {
        $json = $Text | ConvertFrom-Json -ErrorAction Stop
        if ($json -is [array]) { return @($json).Count }
        if ($null -ne $json -and ($json.PSObject.Properties.Name -contains "data") -and $json.data -is [array]) {
            return @($json.data).Count
        }
        if ($null -ne $json) { return 1 }
        return 0
    }
    catch {
        return $null
    }
}

function Get-NormalizedLiveStreamTextLocal {
    param([string]$Text)

    try {
        $json = $Text | ConvertFrom-Json -ErrorAction Stop
        $items = @()

        if ($json -is [array]) {
            $items = @($json)
        }
        elseif ($null -ne $json -and ($json.PSObject.Properties.Name -contains "data") -and $json.data -is [array]) {
            $items = @($json.data)
        }
        else {
            return ""
        }

        $normalizedRows = @(
            $items |
                ForEach-Object {
                    $streamId = ""
                    $name = ""
                    $categoryId = ""
                    $streamType = ""
                    $epgChannelId = ""

                    if ($_.PSObject.Properties.Name -contains "stream_id") {
                        $streamId = [string]$_.stream_id
                    }
                    elseif ($_.PSObject.Properties.Name -contains "id") {
                        $streamId = [string]$_.id
                    }

                    if ($_.PSObject.Properties.Name -contains "name") {
                        $name = [string]$_.name
                    }
                    elseif ($_.PSObject.Properties.Name -contains "title") {
                        $name = [string]$_.title
                    }

                    if ($_.PSObject.Properties.Name -contains "category_id") {
                        $categoryId = [string]$_.category_id
                    }

                    if ($_.PSObject.Properties.Name -contains "stream_type") {
                        $streamType = [string]$_.stream_type
                    }

                    if ($_.PSObject.Properties.Name -contains "epg_channel_id") {
                        $epgChannelId = [string]$_.epg_channel_id
                    }

                    $streamId = $streamId.Trim()
                    $name = $name.Trim()
                    $categoryId = $categoryId.Trim()
                    $streamType = $streamType.Trim()
                    $epgChannelId = $epgChannelId.Trim()

                    if (-not [string]::IsNullOrWhiteSpace($streamId) -or -not [string]::IsNullOrWhiteSpace($name)) {
                        "$streamId|$categoryId|$streamType|$epgChannelId|$name"
                    }
                } |
                Sort-Object -Unique
        )

        return ($normalizedRows -join [Environment]::NewLine)
    }
    catch {
        return ""
    }
}

function Get-NormalizedLiveStreamHashLocal {
    param([string]$Text)

    $normalized = Get-NormalizedLiveStreamTextLocal -Text $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    return Get-Sha256OfTextLocal -Text $normalized
}

function Get-LatestPriorSnapshotLocal {
    param(
        [string]$Directory,
        [string]$CurrentPath
    )

    if (-not (Test-Path -LiteralPath $Directory)) { return $null }

    $currentFull = ""
    try { $currentFull = (Resolve-Path -LiteralPath $CurrentPath -ErrorAction SilentlyContinue).Path } catch { $currentFull = "" }

    $files = @(
        Get-ChildItem -LiteralPath $Directory -File -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object {
                if ([string]::IsNullOrWhiteSpace($currentFull)) { return $true }
                return $_.FullName -ne $currentFull
            } |
            Sort-Object LastWriteTime -Descending
    )

    return ($files | Select-Object -First 1)
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal

$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
$snapshotRootFull = if ([System.IO.Path]::IsPathRooted($SnapshotRoot)) { $SnapshotRoot } else { Join-Path $repoRoot $SnapshotRoot }

New-DirectoryLocal -Path $outputRootFull
New-DirectoryLocal -Path $snapshotRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$startedAt = Get-Date
$signalName = "provider_live_streams_snapshot_completed"

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
        $provider = "xtream"
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
                    event_message = "Provider live streams snapshot blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                    mac_user_id = $MacUserId
                    provider_label = $provider
                } | Out-Null

            Write-Output "BLOCKED: provider live streams snapshot blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
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
                event_message = "Provider live streams snapshot started."
                mac_user_id = $MacUserId
                provider_label = $provider
                gateway_base_url = $gateway
            } | Out-Null
    }

    $script:Stage = "resolve_account_context"
    $contextUrl = "$gateway/_workers/ai/api/get_current_user_context.php?mac_user_id=$MacUserId&debug=1"
    $contextResult = Invoke-JsonGetLocal -Url $contextUrl -TimeoutSec $TimeoutSec

    if (-not $contextResult.ok) {
        throw "Could not resolve account context. endpoint=$(Redact-ScalarLocal -Value $contextUrl) error=$($contextResult.error)"
    }

    $contextResponse = $contextResult.response
    $resolvedProvider = [string](Get-ContextFieldLocal -Response $contextResponse -Path @("context", "provider_label"))
    if ([string]::IsNullOrWhiteSpace($resolvedProvider)) {
        $resolvedProvider = $provider
    }

    $credentials = Get-ProviderCredentialsFromContextLocal -ContextResponse $contextResponse
    $backendCredentialResolutionUsed = $false
    $backendCredentialResolutionOk = $false
    $backendCredentialResolutionError = ""
    $validateUrlRedacted = ""

    if ((-not [bool]$credentials.username_present -or -not [bool]$credentials.password_present) -and -not $SkipBackendCredentialResolution) {
        $script:Stage = "resolve_backend_session_credentials"

        $validateUrl = "$gateway/_workers/ai/api/validate_current_provider_account.php?mac_user_id=$MacUserId&debug=1"
        if (-not [string]::IsNullOrWhiteSpace($provider)) {
            $validateUrl = "$validateUrl&provider=$([uri]::EscapeDataString($provider))"
        }

        $validateUrlRedacted = Redact-ScalarLocal -Value $validateUrl
        $validateResult = Invoke-JsonGetLocal -Url $validateUrl -TimeoutSec $TimeoutSec
        $backendCredentialResolutionUsed = $true
        $backendCredentialResolutionOk = [bool]$validateResult.ok

        if ($validateResult.ok) {
            $validateCredentials = Get-ProviderCredentialsFromContextLocal -ContextResponse $validateResult.response

            if ([string]::IsNullOrWhiteSpace([string]$credentials.dns) -and -not [string]::IsNullOrWhiteSpace([string]$validateCredentials.dns)) {
                $credentials.dns = [string]$validateCredentials.dns
            }

            if (-not [bool]$credentials.username_present -and [bool]$validateCredentials.username_present) {
                $credentials.username = [string]$validateCredentials.username
                $credentials.username_present = $true
            }

            if (-not [bool]$credentials.password_present -and [bool]$validateCredentials.password_present) {
                $credentials.password = [string]$validateCredentials.password
                $credentials.password_present = $true
            }

            if (-not [bool]$credentials.m3u_link_present -and [bool]$validateCredentials.m3u_link_present) {
                $credentials.m3u_link_present = $true
            }
        }
        else {
            $backendCredentialResolutionError = [string]$validateResult.error
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$credentials.dns)) {
        throw "Resolved account context did not include provider DNS."
    }

    if (-not [bool]$credentials.username_present -or -not [bool]$credentials.password_present) {
        throw "Resolved account context did not include provider credentials required for live stream pull. backend_credential_resolution_used=$backendCredentialResolutionUsed backend_credential_resolution_ok=$backendCredentialResolutionOk backend_error=$backendCredentialResolutionError"
    }

    $script:Stage = "call_provider_live_categories"
    $providerUrl = New-ProviderApiUrlLocal `
        -Dns ([string]$credentials.dns) `
        -Username ([string]$credentials.username) `
        -Password ([string]$credentials.password) `
        -Action "get_live_streams"

    $providerResult = Invoke-RawGetLocal -Url $providerUrl -TimeoutSec $TimeoutSec
    $redactedProviderUrl = Redact-ScalarLocal -Value $providerUrl

    if (-not $providerResult.ok) {
        throw "Provider get_live_streams failed. url=$redactedProviderUrl status_code=$($providerResult.status_code) error=$($providerResult.error)"
    }

    if ([string]::IsNullOrWhiteSpace([string]$providerResult.body)) {
        throw "Provider get_live_streams returned an empty body. url=$redactedProviderUrl status_code=$($providerResult.status_code)"
    }

    $script:Stage = "write_snapshot"

    $safeProvider = ($resolvedProvider -replace '[^A-Za-z0-9_.-]', '_')
    $accountSnapshotDir = Join-Path $snapshotRootFull "mac_$MacUserId\$safeProvider"
    New-DirectoryLocal -Path $accountSnapshotDir

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $snapshotPath = Join-Path $accountSnapshotDir "live_streams_$stamp.json"
    $summaryJson = Join-Path $outputRootFull "provider_live_streams_snapshot_summary_$stamp.json"
    $reportCsv = Join-Path $outputRootFull "provider_live_streams_snapshot_report_$stamp.csv"

    Set-Content -LiteralPath $snapshotPath -Value ([string]$providerResult.body) -Encoding UTF8

    $sha256 = Get-Sha256OfTextLocal -Text ([string]$providerResult.body)
    $normalizedSha256 = Get-NormalizedLiveStreamHashLocal -Text ([string]$providerResult.body)
    $itemCount = Get-JsonCountSafeLocal -Text ([string]$providerResult.body)
    $snapshotLength = (Get-Item -LiteralPath $snapshotPath).Length

    $prior = Get-LatestPriorSnapshotLocal -Directory $accountSnapshotDir -CurrentPath $snapshotPath
    $priorHash = ""
    $priorNormalizedHash = ""
    $priorPath = ""
    $rawChanged = $true
    $normalizedChanged = $true
    $changed = $true
    $changeStatus = "first_snapshot"

    if ($null -ne $prior) {
        $priorPath = $prior.FullName
        $priorBody = Get-Content -LiteralPath $prior.FullName -Raw -ErrorAction SilentlyContinue
        $priorHash = Get-Sha256OfTextLocal -Text ([string]$priorBody)
        $priorNormalizedHash = Get-NormalizedLiveStreamHashLocal -Text ([string]$priorBody)

        $rawChanged = ($priorHash -ne $sha256)
        $normalizedChanged = ($priorNormalizedHash -ne $normalizedSha256)

        # DB/import decisions should eventually key off normalized category change,
        # not raw provider JSON byte ordering/formatting.
        $changed = $normalizedChanged

        if ($normalizedChanged) {
            $changeStatus = "changed"
        }
        elseif ($rawChanged) {
            $changeStatus = "raw_changed_normalized_unchanged"
        }
        else {
            $changeStatus = "unchanged"
        }
    }

    $reportRow = [pscustomobject]@{
        mac_user_id = $MacUserId
        provider_label_requested = $provider
        provider_label_resolved = $resolvedProvider
        provider_dns_present = $true
        username_present = [bool]$credentials.username_present
        password_present = [bool]$credentials.password_present
        backend_credential_resolution_used = [bool]$backendCredentialResolutionUsed
        backend_credential_resolution_ok = [bool]$backendCredentialResolutionOk
        action = "get_live_streams"
        provider_url_redacted = $redactedProviderUrl
        provider_http_status = [int]$providerResult.status_code
        provider_elapsed_ms = [int]$providerResult.elapsed_ms
        snapshot_path = $snapshotPath
        snapshot_length = [int64]$snapshotLength
        snapshot_sha256 = $sha256
        normalized_snapshot_sha256 = $normalizedSha256
        item_count_estimate = $itemCount
        prior_snapshot_path = $priorPath
        prior_snapshot_sha256 = $priorHash
        prior_normalized_snapshot_sha256 = $priorNormalizedHash
        raw_changed = [bool]$rawChanged
        normalized_changed = [bool]$normalizedChanged
        change_status = $changeStatus
        changed = [bool]$changed
        db_imported = $false
    }

    $reportRow | Export-Csv -LiteralPath $reportCsv -NoTypeInformation -Encoding UTF8

    $statusValue = "pass"

    $summary = [pscustomobject]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        provider_calls = $true
        db_imported = $false
        db_writes = $false
        mac_user_id = $MacUserId
        provider_label_requested = $provider
        provider_label_resolved = $resolvedProvider
        provider_dns_present = $true
        username_present = [bool]$credentials.username_present
        password_present = [bool]$credentials.password_present
        m3u_link_present = [bool]$credentials.m3u_link_present
        backend_credential_resolution_used = [bool]$backendCredentialResolutionUsed
        backend_credential_resolution_ok = [bool]$backendCredentialResolutionOk
        backend_credential_resolution_error = $backendCredentialResolutionError
        backend_credential_resolution_url_redacted = $validateUrlRedacted
        action = "get_live_streams"
        provider_url_redacted = $redactedProviderUrl
        provider_http_status = [int]$providerResult.status_code
        provider_elapsed_ms = [int]$providerResult.elapsed_ms
        item_count_estimate = $itemCount
        snapshot_path = $snapshotPath
        snapshot_length = [int64]$snapshotLength
        snapshot_sha256 = $sha256
        normalized_snapshot_sha256 = $normalizedSha256
        prior_snapshot_path = $priorPath
        prior_snapshot_sha256 = $priorHash
        prior_normalized_snapshot_sha256 = $priorNormalizedHash
        raw_changed = [bool]$rawChanged
        normalized_changed = [bool]$normalizedChanged
        change_status = $changeStatus
        changed = [bool]$changed
        report_csv = $reportCsv
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

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
                event_message = "Provider live streams snapshot completed."
                provider_calls = $true
                db_imported = $false
                mac_user_id = $MacUserId
                provider_label = $resolvedProvider
                provider_dns_present = $true
                backend_credential_resolution_used = [bool]$backendCredentialResolutionUsed
                item_count_estimate = $itemCount
                change_status = $changeStatus
                changed = [bool]$changed
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
            -SourceTableOrEndpoint "tools/workers/build_provider_live_streams_snapshot.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.live.streams.snapshot"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                provider_calls = $true
                db_imported = $false
                mac_user_id = $MacUserId
                provider_label = $resolvedProvider
                action = "get_live_streams"
                backend_credential_resolution_used = [bool]$backendCredentialResolutionUsed
                item_count_estimate = $itemCount
                change_status = $changeStatus
                changed = [bool]$changed
                snapshot_path = $snapshotPath
                report_csv = $reportCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: provider live streams snapshot completed. status=pass provider_calls=True db_imported=False mac_user_id={0} provider_label=""{1}"" action=get_live_streams item_count_estimate={2} change_status={3} changed={4} backend_credential_resolution_used={5} output_root=""{6}"" run_id={7}" -f `
        $MacUserId, `
        $resolvedProvider, `
        $itemCount, `
        $changeStatus, `
        [bool]$changed, `
        [bool]$backendCredentialResolutionUsed, `
        $outputRootFull, `
        $script:RunId)

    Write-Output ("FILES: snapshot_json=""{0}"" report_csv=""{1}"" summary_json=""{2}""" -f $snapshotPath, $reportCsv, $summaryJson)
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
                event_message = "Provider live streams snapshot failed."
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
            -SourceTableOrEndpoint "tools/workers/build_provider_live_streams_snapshot.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.live.streams.snapshot"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: provider live streams snapshot failed. run_id=$script:RunId $errorMessage"
    exit 1
}

