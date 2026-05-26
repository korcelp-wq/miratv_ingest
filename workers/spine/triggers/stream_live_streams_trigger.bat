@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM --------------------------------------------------
REM MiraTV — Live Stream Trigger (BATCH)
REM --------------------------------------------------

echo.
echo [SERIES] Trigger start

powershell -NoProfile -ExecutionPolicy Bypass ^
 -File "C:\miratv_ingest\workers\spine\call\import_live_channels.ps1

if errorlevel 1 goto FAIL

echo ✅ SERIES TRIGGER COMPLETE
exit /b 0

:FAIL
echo ❌ SERIES TRIGGER FAILED
exit /b 1
