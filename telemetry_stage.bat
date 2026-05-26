@echo off
chcp 65001 > nul
setlocal

echo ==================================================
echo MiraTV MASTER PIPELINE (STEP-BY-STEP UNLOCK)
echo Current unlock: STEP 0 + STEP 1 ONLY (NO LOOP)
echo ==================================================

REM --------------------------------------------------
REM Base paths (adjust if your layout differs)
REM --------------------------------------------------
set BASE=C:\miratv_ingest
set TRIGGERS=%BASE%\triggers
set WORKERS=%BASE%\workers


REM ==================================================
REM STEP 1 — series pipeline allocator (ACTIVE)
REM File: %BASE%\organize_telemetry_files.ps1
REM Purpose: calls server pipeline allocator (lock + next series info)
REM ==================================================
echo.
echo [STEP 1] organize_telemetry_files.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%BASE%\organize_telemetry_files.ps1"
	if errorlevel 1 goto STOP
echo ✅ STEP 1 COMPLETE

 ==================================================

REM ==================================================
REM STEP 2 — upload (ACTIVE)
REM File: %BASE%\upload_logs.ps1
REM Purpose: calls server pipeline allocator (lock + next series info)
REM ==================================================
echo.
echo [STEP 2] upload_logs.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%BASE%\upload_logs.ps1"
	if errorlevel 1 goto STOP
echo ✅ STEP 2 COMPLETE

 ==================================================



echo Upload complete. Waiting 5 seconds before next step...
timeout /t 5 /nobreak >nul

echo Starting next worker...


echo.
echo ==================================================
echo ✅ MASTER SERIES RUNNER FINISHED (0 + 1 ONLY)
echo ==================================================
exit /b 0


:STOP
echo.
echo ==================================================
echo ❌ MASTER STOPPED ON ERROR
echo ==================================================
exit /b 1