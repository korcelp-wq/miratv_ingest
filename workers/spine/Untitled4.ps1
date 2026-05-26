# Stop current learner
Get-Job -Name "AILearning" | Stop-Job | Remove-Job

# Start smart learner
Start-Job -Name "AILearning" -ScriptBlock {
    while($true) {
        & "C:\miratv_ingest\workers\SmartLearner.ps1"
        Start-Sleep -Seconds 300
    }
}
Write-Host "✅ Smart AI Learning started" -ForegroundColor Green