@echo off
setlocal ENABLEEXTENSIONS


set RUN_ID=%1
set START_TS=%DATE% %TIME%
set RESULT=SUCCESS


call "C:\miratv_ingest\workers\db_grinder_worker.bat" %RUN_ID%
if errorlevel 1 set RESULT=FAILURE


:END
set END_TS=%DATE% %TIME%

powershell -NoProfile -Command ^
  "Invoke-RestMethod -Uri 'https://miratv.club/api/telemetry_component.php' -Method POST -ContentType 'application/json' -Body (@{ run_id='%RUN_ID%'; component='%COMPONENT%'; start_ts='%START_TS%'; end_ts='%END_TS%'; result='%RESULT%' } | ConvertTo-Json)"

if "%RESULT%"=="FAILURE" exit /b 1
exit /b 0
