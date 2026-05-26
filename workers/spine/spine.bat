@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ==================================================
REM MiraTV MASTER IMPORT SPINE RUNNER
REM ==================================================

echo =========================================
echo MiraTV MASTER IMPORT SPINE RUNNER START
echo =========================================

REM --------------------------------------------------
REM STEP 1.0 — SERIES
REM --------------------------------------------------
echo.
echo [1.0] Running SERIES pipeline

call "C:\miratv_ingest\workers\spine\triggers\pull_series_trigger.bat"

if %ERRORLEVEL% NEQ 0 goto FAIL

echo ✅ STEP 1.0 COMPLETE

REM --------------------------------------------------
REM STEP 2.0 — LIVE
REM --------------------------------------------------
echo.
echo [2.0] Running LIVE pipeline

call "C:\miratv_ingest\workers\spine\triggers\pull_live_trigger.bat"

if %ERRORLEVEL% NEQ 0 goto FAIL

echo ✅ STEP 2.0 COMPLETE

REM --------------------------------------------------
REM STEP 3.0 — VOD
REM --------------------------------------------------
echo.
echo [3.0] Running VOD pipeline

call "C:\miratv_ingest\workers\spine\triggers\pull_vod_trigger.bat"

if %ERRORLEVEL% NEQ 0 goto FAIL
fd
echo ✅ STEP 3.0 COMPLETE

REM --------------------------------------------------
REM STEP 4.0 — EPG
REM --------------------------------------------------
echo.
echo [4.0] Running EPG pipeline

call "C:\miratv_ingest\workers\spine\triggers\pull_epg_trigger.bat"

if %ERRORLEVEL% NEQ 0 goto FAIL

echo ✅ STEP 4.0 COMPLETE

REM --------------------------------------------------
REM END
REM --------------------------------------------------
echo.
echo 🎯 MIRA TV MASTER IMPORT COMPLETE
exit /b 0


:FAIL
echo.
echo ❌ MIRA TV MASTER IMPORT FAILED
exit /b 1