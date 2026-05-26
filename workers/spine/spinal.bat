@echo off
setlocal EnableExtensions EnableDelayedExpansion




REM ==================================================
REM MiraTV MASTER IMPORT SPINE RUNNER
REM Purpose:
REM  - Canonical orchestration spine
REM  - Sequential trigger execution
REM  - No business logic
REM  - No JSON processes
REM ==================================================

echo =========================================
echo MiraTV MASTER IMPORT SPINE RUNNER START
echo =========================================

REM --------------------------------------------------
REM STEP 1.0 — pull_series_trigger.ps1
REM --------------------------------------------------
echo.
echo [1.0] Running series pipeline trigger
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\spine\triggers\pull_series_trigger.ps1"
if errorlevel 1 goto FAIL
 echo ✅ STEP 1.0 COMPLETE


REM --------------------------------------------------
REM STEP 2.0 — pull_live_trigger.ps1
REM --------------------------------------------------
echo.
echo [2.0] Running series pipeline trigger
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\spine\triggers\pull_series_trigger.ps1"
if errorlevel 1 goto FAIL
 echo ✅ STEP 2.0 COMPLETE


REM --------------------------------------------------
REM STEP 30 — pull_vod_trigger.ps1
REM --------------------------------------------------
echo.
echo [3.0] Running series pipeline trigpull_vod_trigger.ps1ger
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\spine\workers\pull_vod_trigger.ps1
"
if errorlevel 1 goto FAIL
 echo ✅ STEP 3.0 COMPLETE


REM --------------------------------------------------
REM STEP 4.0 — pull_epg_trigger.ps1
REM --------------------------------------------------
echo.
echo [4.0] Running series pipeline trigger
REM call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\spine\workers\pull_epg_trigger.ps1"
REM REM if errorlevel 1 goto FAIL
 echo ✅ STEP 4.0 COMPLETE


