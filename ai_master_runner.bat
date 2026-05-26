@echo off
chcp 65001 > nul
setlocal ENABLEEXTENSIONS

echo ==================================================
echo MiraTV MASTER PIPELINE (STEP-BY-STEP UNLOCK)
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

REM ==================================================
REM STEP 0
REM ==================================================
echo.
echo [STEP 0] series pipeline allocator
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\0series_pipeline_trigger.ps1"
if errorlevel 1 goto STOP

REM ==================================================
REM STEP 1
REM ==================================================
echo.
echo [STEP 1] series details worker
call "%WORKERS%\1series_details_worker.bat"
if errorlevel 1 goto STOP

REM ==================================================
REM DB PIPELINE TRIGGER (OPTIONAL / ADDITIVE)
REM ==================================================
if exist "%TRIGGERS%\db_grinder.trigger" (
    echo DB grinder trigger detected
    call "%WORKERS%\db_grinder_trigger.bat" %RUN_ID%
    if errorlevel 1 goto STOP
)

REM ==================================================
REM NORMAL COMPLETION
REM ==================================================
goto TELEMETRY_END

:STOP
set RESULT=FAILURE

:TELEMETRY_END
set END_TS=%DATE% %TIME%

powershell -NoProfile -Command ^
  "Invoke-RestMethod -Uri 'https://miratv.club/api/telemetry_component.php' -Method POST -ContentType 'application/json' -Body (@{ run_id='%RUN_ID%'; component='%COMPONENT%'; start_ts='%START_TS%'; end_ts='%END_TS%'; result='%RESULT%' } | ConvertTo-Json)"

if "%RESULT%"=="FAILURE" exit /b 1
exit /b 0
