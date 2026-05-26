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
REM STEP 0 — series pipeline allocator (ACTIVE)
REM File: triggers\0series_pipeline_trigger.ps1
REM Purpose: calls server pipeline allocator (lock + next series info)
REM ==================================================
echo.
echo [STEP 0] 0series_pipeline_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\0series_pipeline_trigger.ps1"
	if errorlevel 1 goto STOP
echo ✅ STEP 0 COMPLETE

pause
 ==================================================
STEP 1 — series details worker (ACTIVE)
REM File: workers\1series_details_worker.bat
REM Purpose: runs series_details_worker.ps1 which fetches series ID itself
 ==================================================
REM echo.
REM echo [STEP 1] 1series_details_worker.bat - Skipped
echo --------------------------------------------------
 call "%base%\series_details_worker.bat"
	if errorlevel 1 goto STOP
 echo ✅ STEP 1 COMPLETE


echo Upload complete. Waiting 5 seconds before next step...
timeout /t 5 /nobreak >nul

echo Starting next worker...

REM ==================================================
REM STEP 2.2 — 2_2_raw_local_parse_trigger.ps1
REM File: triggers\2parse_trigger.ps1
REM Purpose: server-side parse stage (file-system driven)
REM ==================================================
REM  echo.
 echo [STEP 2.2] 2_2_raw_local_parse_trigger.ps1 - skipping 
REM  echo --------------------------------------------------
REM  powershell -NoProfile -ExecutionPolicy Bypass ^
REM   -File "%TRIGGERS%\\2_2_raw_local_parse_trigger.ps1"
REM 	if errorlevel 1 goto STOP
   
echo ✅ STEP 2 COMPLETE


echo Step complete. Waiting 5 seconds before next step...
timeout /t 5 /nobreak >nul

echo Starting next worker...


REM ==================================================
REM STEP 2.3 — normalize trigger (LOCKED)
REM File: triggers\2_3_raw_local_normalize_trigger.ps1
REM Purpose: server-side normalize stage
REM ==================================================
echo.
echo [STEP 2.3] 2_3_raw_local_normalize_trigger.ps - skipped 
echo --------------------------------------------------
REM powershell -NoProfile -ExecutionPolicy Bypass ^
REM   -File "%TRIGGERS%\3normalize_trigger.ps1"

if errorlevel 1 goto STOP
echo ✅ STEP 2.3 COMPLETE



echo Upload complete. Waiting 5 seconds before next step...
timeout /t 5 /nobreak >nul

echo Starting next worker...


REM ==================================================
REM STEP 2.5 2.5 — Router 
REM File: triggers\raw_router_trigger.ps1
REM Purpose:route to correct grinder 
REM ==================================================
echo.
echo [STEP 2.5] 2.5 raw_router_trigger.ps1 (series details)
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
   -File "%TRIGGERS%\raw_router_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 2.5 COMPLETE



echo Step complete. Waiting 10 seconds before next step...
timeout /t 10 /nobreak >nul

echo Starting next worker...


REM ==================================================
REM STEP 3 — Default Grinder (LOCKED)
REM File: triggers\series_grinder_trigger
REM Purpose: server-side default grinder
REM ==================================================
echo.
echo [STEP 3] default grinder
REM echo --------------------------------------------------
   call "%TRIGGERS%\series_grinder_trigger.bat

if errorlevel 1 goto STOP
echo ✅ STEP 3 COMPLETE



echo Step complete. Waiting 5 seconds before next step...
timeout /t 9 /nobreak >nul

echo Starting next worker...


REM ==================================================
REM [STEP 3.5] 3.5 — Array Grinder
REM File: triggers\3_5_series_grinder_arrays_trigger.ps1
REM Purpose:grind out normal input file for upload/ingest 
REM ==================================================
echo. (series details)
echo [STEP 3.5] 3_5_series_grinder_arrays_trigger.ps1 
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
   -File "%TRIGGERS%\3_5_series_grinder_arrays_trigger.ps1

if errorlevel 1 goto STOP
echo ✅ STEP 3.5 COMPLETE

echo Step complete. Waiting 5 seconds before next step...
timeout /t 9 /nobreak >nul

echo Starting next worker...

REM ==================================================
REM New Grinders Go HERE before the ingest
REM File: triggers\raw_router_trigger.ps1
REM Purpose:grind out normal input file for upload/ingest 
REM ==================================================



REM ==================================================
REM [STEP 3.6] — RESERVED for Future Grinder (LOCKED)
REM Purpose: future modular insert (Batch triggers)
REM ==================================================
echo.
echo [STEP 3.6] RESERVED (future module)
REM echo --------------------------------------------------
REM REM call "%TRIGGERS%\3.6_*.bat"
REM REM if errorlevel 1 goto STOP
REM echo ✅ STEP 3.6 COMPLETE



REM ==================================================
REM STEP 3.7 — RESERVED for Future Grinder (LOCKED)
REM Purpose: future modular insert (Powershell triggers)
REM ==================================================
echo.
 echo [STEP 3.7] RESERVED (future module)
REM echo --------------------------------------------------
REM powershell -NoProfile -ExecutionPolicy Bypass -File "%TRIGGERS%\3.7_*.ps1"
REM  if errorlevel 1 goto STOP
REM echo ✅ STEP 3.7 COMPLETE


REM ==================================================
REM STEP 4 — series pipeline trigger (LOCKED)
REM File: triggers\3ingest_trigger.bat
REM Purpose: server-side episode stream resolution

REM ==================================================
REM        echo.
REM        echo [STEP 4] 3ingest_trigger.bat
REM        echo 
REM --------------------------------------------------
REM       call "%TRIGGERS%\3ingest_trigger.bat"
REM        if errorlevel 1 goto STOP
REM        echo ✅ STEP 4 COMPLETE again (sorta)


REM ==================================================
REM STEP 5 — 9materialize_series_trigger.ps1
REM File: triggers 9materialize_series_trigger.ps1
REM Purpose: server-side episode stream resolution
==================================================
REM echo.
REM echo [STEP 5.5] 9materialize_series_trigger.ps1
REM  powershell -ExecutionPolicy Bypass -File "%TRIGGERS%\9materialize_series_trigger.ps1
REM  REM  if errorlevel 1 goto STOP
REM  echo ✅ STEP 5 COMPLETE - skipped for now 

REM ==================================================
REM STEP 6 — upload trigger (LOCKED)
REM File: triggers\6upload_trigger.bat
REM Purpose: upload raw_store files to server (then move to processed)
REM ==================================================
echo.
echo [STEP 6] 6upload_trigger.bat
echo ==================================================
call "%TRIGGERS%\6upload_trigger.bat"
if errorlevel 1 goto STOP
echo ✅ STEP 6 COMPLETE

echo Upload complete. Waiting 10 seconds before next step...
timeout /t 10 /nobreak >nul

echo Starting next worker...


REM ==================================================
REM STEP 7 4.2 — raw ingest trigger (series details first)
REM File: triggers\4-2raw_ingest_trigger.ps1
REM Purpose: server-side raw ingest from filesystem into DB
REM ==================================================
echo.
echo [STEP 7] 4.2 raw_ingest_trigger.ps1 (series details)
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
   -File "%TRIGGERS%\4-2raw_ingest_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 7 COMPLETE
==================================================


echo Upload complete. Waiting 10 seconds before next step...
timeout /t 10 /nobreak >nul

echo Starting next worker...


REM ==================================================
REM STEP 8 — raw ingest trigger (LOCKED)
REM File: triggers\4raw_ingest_trigger.ps1
REM Purpose: server-side raw ingest from filesystem into DB
REM ==================================================
echo.
echo [STEP 8] 4.4raw_ingest_trigger.ps1 (everything else)
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
   -File "%TRIGGERS%\4raw_ingest_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 8 COMPLETE


REM ==================================================
REM STEP 9 — 9episode_resolver_trigger.ps1 (LOCKED)
REM File: triggers\episode_resolver_trigger.ps1
REM Purpose: server-side episode stream resolution
REM ==================================================
  echo.
  echo [STEP 9] 9episode_resolver_trigger.ps1
  echo --------------------------------------------------
  powershell -NoProfile -ExecutionPolicy Bypass ^
    -File "%TRIGGERS%\9episode_resolver_trigger.ps1"
  if errorlevel 1 goto STOP
  echo ✅ STEP 9 COMPLETE




REM ==================================================
REM STEP 10 — 10 finalize_series.php (LOCKED)
REM File: triggers\10finalize_series_trigger.ps1
REM Purpose: finalize series stream 
REM ==================================================
  echo.
  echo [STEP 10] 1010finalize_series_trigger.ps1
  echo --------------------------------------------------
  powershell -NoProfile -ExecutionPolicy Bypass ^
    -File "%TRIGGERS%\10finalize_series_trigger.ps1"
  if errorlevel 1 goto STOP
  echo ✅ STEP 10 COMPLETE



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