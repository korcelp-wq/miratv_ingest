#!/usr/bin/env pwsh
param(
    [string]$DashboardRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [int]$Port = 0
)

$serverScript = Join-Path $DashboardRoot 'dashboard_server.ps1'
$configPath   = Join-Path $DashboardRoot 'dashboard_config.json'

if (-not (Test-Path $serverScript)) {
    Write-Host "[ERR] Dashboard server not found: $serverScript" -ForegroundColor Red
    exit 1
}

$argsList = @('-ExecutionPolicy', 'Bypass', '-File', $serverScript, '-ConfigPath', $configPath)
if ($Port -gt 0) {
    $argsList += @('-Port', [string]$Port)
}

Write-Host "[START] Starting CVI Web Dashboard..." -ForegroundColor Cyan
Write-Host "        Root: $DashboardRoot" -ForegroundColor DarkGray
Start-Process powershell.exe -ArgumentList $argsList -WindowStyle Normal | Out-Null
