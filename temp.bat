@echo off
chcp 65001 > nul
setlocal
set BASE=C:\miratv_ingest
set TRIGGERS=%BASE%\triggers
set WORKERS=%BASE%\workers



REM ==================================================
REM STEP 2.3 — normalize trigger (LOCKED)
REM File: triggers\2_3_raw_local_normalize_trigger.ps1
REM Purpose: server-side normalize stage
REM ==================================================
echo.
echo [STEP 2.3] 2_3_raw_local_normalize_trigger.ps
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\2_3_raw_local_normalize_trigger.ps1"

if errorlevel 1 goto STOP
echo ✅ STEP 2.3 COMPLETE
