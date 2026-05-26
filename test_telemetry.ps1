# Test script for telemetry emit module
Import-Module "C:\miratv_ingest\_workers\_accessories.psm1" -Force

Write-Host "Testing telemetry emit functions..." -ForegroundColor Cyan

# Test Ops event
Emit-Ops -Event "TEST_EVENT" -Component "test_script" -Fields @{test="value"; count=1}

# Test Lake event
Emit-Lake -Event "TEST_SIGNAL" -Component "test_script" -Fields @{confidence=0.95}

# Test IGM event
Emit-IGM -Event "TEST_GOVERNANCE" -Component "test_script" -Fields @{rule_id=42; decision="allowed"}

Write-Host "✅ Test events emitted. Check spool directories." -ForegroundColor Green
