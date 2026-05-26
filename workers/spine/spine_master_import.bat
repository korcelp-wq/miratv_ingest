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
REM STEP 1.0 — SERIES (INDEX ONLY)
REM --------------------------------------------------
echo.
echo [1.0] Running SERIES pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_series_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 1.0 COMPLETE

REM --------------------------------------------------
REM STEP 2.0 — LIVE STREAMS
REM --------------------------------------------------
echo.
echo [2.0] Running LIVE STREAMS pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_live_streams_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 2.0 COMPLETE

REM --------------------------------------------------
REM STEP 2.1 — LIVE CATEGORIES
REM --------------------------------------------------
echo.
echo [2.1] Running LIVE CATEGORIES pipeline

call C:\miratv_ingest\workers\spine\triggers\pull_live_cat_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 2.1 COMPLETE

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
REM STEP 4.0 — EPG (XML → JSON → INGEST)
REM --------------------------------------------------
echo.
echo [4.0] Running EPG pipeline

REM --- Normalize XML first (server-side or local helper)
REM call C:\miratv_ingest\workers\spine\triggers\convert_epg_trigger.bat
REM if errorlevel 1 goto FAIL

REM --- Ingest normalized EPG
call C:\miratv_ingest\workers\spine\triggers\pull_epg_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 4.0 COMPLETE

REM --------------------------------------------------
REM STEP 5.0 — UPLOAD / PUBLISH PIPELINE FILES
REM --------------------------------------------------
echo.
echo [5.0] Upload pipeline files

  call C:\miratv_ingest\workers\spine\triggers\upload_pull_trigger.bat
  if errorlevel 1 goto FAIL

echo ✅ STEP 5.0 SKipped 

REM =================================================
REM END OF Import without Upload 
REM =================================================

echo ===================================================
echo MiraTV MASTER DATABASE POPULATE SPINE UPDATE START
echo ===================================================

REM --------------------------------------------------
REM STEP 1.0 — SERIES
REM --------------------------------------------------
echo.
echo [1.0] Running SERIES pipeline

   call C:\miratv_ingest\workers\spine\triggers\stream_series_trigger.bat
   if errorlevel 1 goto FAIL

echo ✅ STEP 1.0 COMPLETED

REM --------------------------------------------------
REM STEP 2.0 — LIVE Streams - stream_live_streams_trigger.bat
REM --------------------------------------------------
echo.
echo [2.0] Running LIVE Streams pipeline

  call C:\miratv_ingest\workers\spine\triggers\stream_live_streams_trigger.bat
  if errorlevel 1 goto FAIL

echo ✅ STEP 2.0 COMPLETED


REM --------------------------------------------------
REM STEP 2.0A — LIVE Categories
REM --------------------------------------------------
echo.
echo [2.0A] Running LIVE Categories pipeline

  call C:\miratv_ingest\workers\spine\triggers\stream_live_cat_trigger.bat
  if errorlevel 1 goto FAIL

echo ✅ STEP 2.0A COMPLETED

REM --------------------------------------------------
REM STEP 3.0 — VOD STREAMS
REM --------------------------------------------------
echo.
echo [3.0] Running VOD STREAMS pipeline

  call C:\miratv_ingest\workers\spine\triggers\stream_vod_streams_trigger.bat
  if errorlevel 1 goto FAIL

echo ✅ STEP 3.0 COMPLETED

REM --------------------------------------------------
REM STEP 3.0A — VOD CATEGORIES
REM --------------------------------------------------
echo.
echo [3.0A] Running VOD CATEGORIES pipeline

  call C:\miratv_ingest\workers\spine\triggers\stream_vod_cat_trigger.bat
  if errorlevel 1 goto FAIL

echo ✅ STEP 3.0A COMPLETED

REM --------------------------------------------------
REM STEP 4.0 — EPG
REM --------------------------------------------------
echo.
echo [4.0] Running EPG pipeline

call C:\miratv_ingest\workers\spine\triggers\stream_epg_trigger.bat
if errorlevel 1 goto FAIL

echo ✅ STEP 4.0 COMPLETE


echo.
echo 🎯 MIRA TV MASTER IMPORT COMPLETE
exit /b 0

:FAIL
echo.
echo ❌ MIRA TV MASTER IMPORT FAILED
exit /b 1
