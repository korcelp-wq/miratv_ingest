# Stop the current AI Learning job
Get-Job -Name "AILearning" | Stop-Job | Remove-Job

# Start a new one with the simple learner
Start-Job -Name "AILearning" -ScriptBlock {
    while($true) {
        & "C:\miratv_ingest\workers\SimpleLearner.ps1"
        Start-Sleep -Seconds 60
    }
}
Write-Host "✅ Simple AI Learning started" -ForegroundColor Green