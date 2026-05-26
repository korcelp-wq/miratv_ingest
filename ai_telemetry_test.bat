@echo off
chcp 65001 > nul
setlocal ENABLEEXTENSIONS

echo ==================================================
echo Step 1 MiraTV MASTER PIPELINE (STEP-BY-STEP UNLOCK)
echo ==================================================

REM --------------------------------------------------
REM Base paths
REM --------------------------------------------------
set BASE=C:\miratv_ingest
set TRIGGERS=%BASE%\triggers
set WORKERS=%BASE%\workers

REM --------------------------------------------------
REM TELEMETRY INIT
REM --------------------------------------------------
set COMPONENT=master_runner
set RUN_ID=MR_%DATE:~-4%%DATE:~4,2%%DATE:~7,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set START_TS=%DATE% %TIME%
set RESULT=SUCCESS
echo ✅ SETUP  COMPLETE

REM ==================================================
echo Mira TV Pipeline Allocator (Series ID)
REM ==================================================
REM STEP 1 — series pipeline allocator (ACTIVE)
REM File: triggers\0series_pipeline_trigger.ps1
REM Purpose: calls server pipeline allocator (lock + next series info)
REM ==================================================
echo.
echo [STEP 1] 0series_pipeline_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\0series_pipeline_trigger.ps1"
	if errorlevel 1 goto STOP
echo ✅ STEP 0 COMPLETE

REM ==================================================
echo STEP 2 — series details worker (ACTIVE)
REM File: workers\1series_details_worker.bat
REM Purpose: runs series_details_worker.ps1 which fetches series ID itself
REM ==================================================
 echo.
 echo [STEP 2] 1series_details_worker.bat 
echo --------------------------------------------------
 call "%base%\series_details_worker.bat"
	if errorlevel 1 goto STOP
 echo ✅ STEP 2 COMPLETE


echo Upload complete. Waiting 5 seconds before next step...
timeout /t 5 /nobreak >nul

echo Starting next worker...

REM ==================================================
REM DB PIPELINE TRIGGER (OPTIONAL / ADDITIVE)
REM ==================================================
call "%TRIGGERS%\db_grinder_trigger.bat" 
    if errorlevel 1 goto STOP

echo ✅ STEP 3 COMPLETE
REM ==================================================
REM NORMAL COMPLETION
REM ==================================================
goto TELEMETRY_END

REM ==================================================
REM STEP 6 — upload trigger (LOCKED)
REM File: triggers\6upload_trigger.bat
REM Purpose: upload raw_store files to server (then move to processed)
REM ==================================================
echo.
echo [STEP 6] 6upload_trigger.bat
echo ==================================================
call "%TRIGGERS%\db_grinder_upload_trigger.bat"
if errorlevel 1 goto STOP
echo ✅ STEP 6 COMPLETE


REM ==================================================
echo STEP 4 — start master_runner
REM File: Base\1series_details_worker.bat
REM Purpose: runs series_details_worker.ps1 which fetches series ID itself
REM ==================================================
 echo.
 echo [STEP 2] Master Runner
echo --------------------------------------------------
REM call "%base%\master_runner.bat"
REM	if errorlevel 1 goto STOP
 echo ✅ STEP 2 COMPLETE

:STOP
set RESULT=FAILURE

:TELEMETRY_END
set END_TS=%DATE% %TIME%

powershell -NoProfile -Command ^
  "Invoke-RestMethod -Uri 'https://miratv.club/api/telemetry_component.php' -Method POST -ContentType 'application/json' -Body (@{ run_id='%RUN_ID%'; component='%COMPONENT%'; start_ts='%START_TS%'; end_ts='%END_TS%'; result='%RESULT%' } | ConvertTo-Json)"

if "%RESULT%"=="FAILURE" exit /b 1
exit /b 0