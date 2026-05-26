@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ==================================================
REM MiraTV MASTER IMPORT SPINE RUNNER
REM Purpose:
REM  - Canonical orchestration spine
REM  - Sequential trigger execution
REM  - No business logic
REM ==================================================

echo =========================================
echo MiraTV MASTER IMPORT SPINE RUNNER START
echo =========================================

REM --------------------------------------------------
REM STEP 1.0 — SERIES
REM --------------------------------------------------
echo.
echo [1.0] Running SERIES pipeline

 call C:\miratv_ingest\workers\spine\triggers\pull_series_trigger.bat
 if errorlevel 1 goto FAIL

echo ✅ STEP 1.0 COMPLETE

REM --------------------------------------------------
REM STEP 2.0 — LIVE Streams
REM --------------------------------------------------
echo.
echo [2.0] Running LIVE pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_live_streams_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 2.0 COMPLETE


REM --------------------------------------------------
REM STEP 2.0 — LIVE Categories
REM --------------------------------------------------
echo.
echo [2.0] Running LIVE pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_live_cat_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 2.0 COMPLETE

REM --------------------------------------------------
REM STEP 3.0 — VOD STREAMS
REM --------------------------------------------------
echo.
echo [3.0] Running VOD STREAMS pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_vod_streams_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 3.0 COMPLETE

REM --------------------------------------------------
REM STEP 3.1 — VOD CATEGORIES
REM --------------------------------------------------
echo.
echo [3.1] Running VOD CATEGORIES pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_vod_cat_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 3.1 COMPLETE

REM --------------------------------------------------
REM STEP 4.0 — EPG
REM --------------------------------------------------
echo.
echo [4.0] Running EPG pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_epg_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 4.0 COMPLETE


REM --------------------------------------------------
REM STEP 5.0 — upload docs
REM --------------------------------------------------
echo.
echo [5.0] Upload pipeline files

call C:\miratv_ingest\workers\spine\triggers\upload_pull_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 5.0 COMPLETE


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
