# MiraTV Frame Capture Preview Common Helpers
# Extracted from tools/workers/capture_series_frame_artwork.ps1 as a no-behavior-change helper module.

Set-StrictMode -Version Latest

function Convert-ToArraySafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

function Convert-ToIntSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $parsed = 0

    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Convert-ToJsonSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$Depth = 8
    )

    if ($null -eq $Value) {
        return "null"
    }

    try {
        return ($Value | ConvertTo-Json -Depth $Depth -Compress -ErrorAction Stop)
    }
    catch {
        return "{`"json_error`":`"$($_.Exception.Message)`"}"
    }
}

function Get-StringSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-RedactedUrlSummary {
    [CmdletBinding()]
    param(
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{
            url_present = $false
            host = ""
            scheme = ""
            path_hint = ""
            url_sha256 = ""
        }
    }

    try {
        $uri = [System.Uri]$Url
        $segments = @($uri.Segments | ForEach-Object { $_.Trim('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $tail = @($segments | Select-Object -Last 2) -join "/"

        return [pscustomobject]@{
            url_present = $true
            host = $uri.Host
            scheme = $uri.Scheme
            path_hint = $tail
            url_sha256 = Get-StringSha256 -Text $Url
        }
    }
    catch {
        return [pscustomobject]@{
            url_present = $true
            host = "parse_failed"
            scheme = "parse_failed"
            path_hint = "parse_failed"
            url_sha256 = Get-StringSha256 -Text $Url
        }
    }
}

function Get-SecretRedactedText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string[]]$Secrets
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $redacted = $Text

    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $redacted = $redacted.Replace($secret, "REDACTED")
        }
    }

    return $redacted
}

function Get-SafeProbeStderrSnippet {
    [CmdletBinding()]
    param(
        [string]$Text = "",
        [string[]]$Secrets = @(),
        [int]$MaxLength = 240
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $safe = Get-SecretRedactedText -Text $Text -Secrets $Secrets

    # ffprobe can echo a request URL in stderr. Never allow full playback URLs into logs.
    $safe = [regex]::Replace($safe, '(?i)https?://[^\s''"<>]+', 'REDACTED_URL')

    # Remove terminal/control noise and collapse multiline stderr into a compact one-line diagnostic.
    $safe = [regex]::Replace($safe, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ' ')
    $safe = [regex]::Replace($safe, '\s+', ' ').Trim()

    if ($MaxLength -lt 40) {
        $MaxLength = 40
    }

    if ($safe.Length -gt $MaxLength) {
        return $safe.Substring(0, $MaxLength)
    }

    return $safe
}



function Write-FrameCaptureModuleEvent {
    [CmdletBinding()]
    param(
        [hashtable]$LogContext = @{},
        [string]$ModuleName = "",
        [string]$Subcomponent = "",
        [string]$ModuleStage = "",
        [string]$EventType = "module_event",
        [string]$Status = "info",
        [hashtable]$Payload = @{},
        [string]$LogRoot = "runtime/logs"
    )

    if ($null -eq $LogContext) {
        return
    }

    if (-not (Get-Command Write-JobLog -ErrorAction SilentlyContinue)) {
        return
    }

    $data = @{}

    if ($null -ne $Payload) {
        foreach ($key in $Payload.Keys) {
            $data[$key] = $Payload[$key]
        }
    }

    $data["module_name"] = $ModuleName
    $data["subcomponent"] = $Subcomponent
    $data["module_stage"] = $ModuleStage
    $data["module_event_type"] = $EventType

    $runId = ""
    $jobName = "capture_series_frame_artwork"
    $workerName = "series_frame_capture_artwork_worker"
    $component = "materialization_queue_worker"
    $environment = "dev"

    if ($LogContext.ContainsKey("run_id")) { $runId = [string]$LogContext["run_id"] }
    if ($LogContext.ContainsKey("job_name")) { $jobName = [string]$LogContext["job_name"] }
    if ($LogContext.ContainsKey("worker_name")) { $workerName = [string]$LogContext["worker_name"] }
    if ($LogContext.ContainsKey("component")) { $component = [string]$LogContext["component"] }
    if ($LogContext.ContainsKey("environment")) { $environment = [string]$LogContext["environment"] }

    Write-JobLog `
        -RunId $runId `
        -JobName $jobName `
        -WorkerName $workerName `
        -Component $component `
        -Environment $environment `
        -Status $Status `
        -EventType $EventType `
        -SourceName $Subcomponent `
        -Data $data `
        -LogRoot $LogRoot | Out-Null
}

Export-ModuleMember -Function Convert-ToArraySafe, Get-PropertyValue, Convert-ToIntSafe, Convert-ToJsonSafe, Get-StringSha256, Get-RedactedUrlSummary, Get-SecretRedactedText, Get-SafeProbeStderrSnippet, Write-FrameCaptureModuleEvent
