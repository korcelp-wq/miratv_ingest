@echo off
setlocal ENABLEEXTENSIONS

set COMPONENT=db_grinder_worker
set RUN_ID=%1
set START_TS=%DATE% %TIME%
set RESULT=SUCCESS

REM --------------------------------------------------
REM COPY RAW INPUT
REM --------------------------------------------------
xcopy "C:\miratv_ingest\raw_store\*" ^
      "C:\miratv_ingest\raw_store_db\" ^
      /E /I /Y >nul || set RESULT=FAILURE

REM --------------------------------------------------
REM COPY EXHAUST (OPTIONAL BUT RECOMMENDED)
REM --------------------------------------------------
REM xcopy "C:\miratv_ingest\exhaust\*" ^
REM       "C:\miratv_ingest\exhaust_db\" ^
REM       /E /I /Y >nul
REM --------------------------------------------------


REM --------------------------------------------------
REM UPLOAD + INGEST
REM --------------------------------------------------
  call "C:\miratv_ingest\triggers\db_grinder_upload_trigger.bat"
	if errorlevel 1 set RESULT=FAILURE

REM --------------------------------------------------
REM TELEMETRY
REM --------------------------------------------------
set END_TS=%DATE% %TIME%

powershell -NoProfile -Command ^
  "Invoke-RestMethod -Uri 'https://miratv.club/api/telemetry_component.php' -Method POST -ContentType 'application/json' -Body (@{ run_id='%RUN_ID%'; component='%COMPONENT%'; start_ts='%START_TS%'; end_ts='%END_TS%'; result='%RESULT%' } | ConvertTo-Json)"

if "%RESULT%"=="FAILURE" exit /b 1
exit /b 0
