@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ==================================================
REM MiraTV MASTER RUNNER
REM Purpose:
REM  - Canonical orchestration spine
REM  - Sequential trigger execution
REM  - No business logic
REM  - No JSON processes
REM ==================================================

echo =========================================
echo MiraTV MASTER RUNNER START
echo =========================================

REM --------------------------------------------------
REM STEP 00 ? Kick remote pipeline (optional bootstrap)
REM --------------------------------------------------
echo.
echo [00] Running series pipeline trigger

for /f "tokens=2 delims==" %%A in ('pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\00_series_pipeline_trigger.ps1" ^| findstr /B "SERIES_ID="') do set "MIRATV_SERIES_ID=%%A"

if "%MIRATV_SERIES_ID%"=="" (
    echo ERROR: Failed to retrieve SERIES_ID
    goto FAIL
)

echo [00] STEP 0 COMPLETE
echo [00] %MIRATV_SERIES_ID%

REM ==================================================
REM STEP 1 ? series details worker (ACTIVE)
REM File: workers\1series_details_worker.bat
REM Purpose: runs series_details_worker.ps1 which fetches series ID itself
REM ==================================================
REM echo.
REM echo [STEP 1] 1series_details_worker.bat 
echo ==================================================
 call "C:\miratv_ingest\series_details_worker.bat"
	if errorlevel 1 goto STOP
 echo ? STEP 1 COMPLETE


REM --------------------------------------------------
REM STEP 02 ? Raw router (classification + pickup)
REM --------------------------------------------------
echo.
echo [02] Running raw router
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\03_raw_router_trigger.ps1"
if errorlevel 1 goto FAIL

 echo ? STEP 02 COMPLETE


REM --------------------------------------------------
REM STEP 02.4 ? Raw router (classification + pickup)
REM --------------------------------------------------
REM echo.
REM echo [02.4] Running raw router
REM call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\_workers\series_normalize.ps1"
REM if errorlevel 1 goto FAIL

REM  echo ? STEP 02.4 COMPLETE



REM --------------------------------------------------
REM STEP 02.5 ? Local series grinder (core extraction)
REM --------------------------------------------------
echo.
echo [02.5] Running series grinder
call "C:\miratv_ingest\triggers\01_series_grinder_trigger.bat"
if errorlevel 1 goto FAIL

 echo ? STEP 02.5 COMPLETE


REM --------------------------------------------------
REM STEP 03 ? Array variants (late / blended formats)
REM --------------------------------------------------
echo.
echo [03] Running series array grinder
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\02_series_grinder_arrays_trigger.ps1"
if errorlevel 1 goto FAIL

 echo ? STEP 03 COMPLETE

REM --------------------------------------------------
REM STEP 04 ? Raw ingest (primary pass)
REM --------------------------------------------------
echo.
echo [04] Running raw ingest (pass 1)
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\04_raw_ingest_trigger.ps1"
if errorlevel 1 goto FAIL

 echo ? STEP 04 COMPLETE

REM --------------------------------------------------
REM STEP 05 ? Raw ingest (secondary / cleanup pass)
REM --------------------------------------------------
echo.
echo [05] Running raw ingest (pass 2)
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\05_raw_ingest_pass2_trigger.ps1"
if errorlevel 1 goto FAIL

 echo ? STEP 05 COMPLETE


REM --------------------------------------------------
REM STEP 06 ? Materialize series records
REM --------------------------------------------------
REM echo.
REM echo [06] Materializing series
REM call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\07_materialize_series_trigger.ps1"
REM if errorlevel 1 goto FAIL
REM echo ? STEP 06 COMPLETE


REM --------------------------------------------------
REM STEP 07 ? Upload normalized artifacts
REM --------------------------------------------------
 echo.
 echo [07] Uploading series artifacts
call "C:\miratv_ingest\triggers\06_upload_trigger.bat"
 if errorlevel 1 goto FAIL

 echo ? STEP 07 COMPLETE

REM ==================================================
REM STEP 7.4.2 ? raw ingest trigger (series details first)
REM File: triggers\4-2raw_ingest_trigger.ps1
REM Purpose: server-side raw ingest from filesystem into DB
REM ==================================================
echo.
echo [STEP 07.4.2 raw_ingest_trigger.ps1 (series details)
echo --------------------------------------------------
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\4-2raw_ingest_trigger.ps1"
if errorlevel 1 goto STOP
echo ? STEP 7.4.2 COMPLETE
==================================================

REM ==================================================
REM STEP 8 ? raw ingest trigger (LOCKED)
REM File: triggers\4raw_ingest_trigger.ps1
REM Purpose: server-side raw ingest from filesystem into DB
REM ==================================================
echo.
echo [STEP 8] 4.4raw_ingest_trigger.ps1 (everything else)
echo --------------------------------------------------
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\4raw_ingest_trigger.ps1"
if errorlevel 1 goto STOP
echo ? STEP 8 COMPLETE

REM ==================================================
REM STEP 9 ? 9episode_resolver_trigger.ps1 (LOCKED)
REM File: triggers\episode_resolver_trigger.ps1
REM Purpose: server-side episode stream resolution
REM ==================================================
  echo.
  echo [STEP 9] 9episode_resolver_trigger.ps1
  echo --------------------------------------------------
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\9episode_resolver_trigger.ps1"
  if errorlevel 1 goto STOP
  echo ? STEP 9 COMPLETE

echo MIRATV_SERIES_ID=%MIRATV_SERIES_ID%


REM ==================================================
REM STEP 9.5 — 95materialize_series_trigger.ps1
REM File: triggers\95materialize_series_trigger.ps1
REM Purpose: fill missing canonical fields on parent series row
REM ==================================================
echo.
echo [STEP 9.5] 95materialize_series_trigger.ps1 -SeriesId %MIRATV_SERIES_ID%
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\triggers\95materialize_series_trigger.ps1" -SeriesId %MIRATV_SERIES_ID%
if errorlevel 1 goto STOP
echo ✅ STEP 9.5 COMPLETE


REM --------------------------------------------------
REM STEP 10 ? Finalize series (remote)
REM --------------------------------------------------
echo.
echo [10] Finalizing series
call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\08_finalize_series_trigger.ps1"
if errorlevel 1 goto FAIL

echo.
echo =========================================
echo MiraTV MASTER RUNNER COMPLETE ? SUCCESS
echo =========================================

endlocal
exit /b 0

:FAIL
echo.
echo =========================================
echo MiraTV MASTER RUNNER FAILED
echo =========================================
endlocal
exit /b 1
