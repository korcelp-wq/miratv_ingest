@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM --------------------------------------------------
REM MiraTV — EPG Trigger (BATCH)
REM --------------------------------------------------

echo.
echo [EPG] Trigger start

powershell -NoProfile -ExecutionPolicy Bypass ^
 -File "C:\miratv_ingest\workers\spine\workers\pull_epg_worker.ps1"

if errorlevel 1 goto FAIL

echo ✅ EPG TRIGGER COMPLETE
exit /b 0

:FAIL
echo ❌ EPG TRIGGER FAILED
exit /b 1

