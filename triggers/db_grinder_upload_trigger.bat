@echo off
setlocal ENABLEEXTENSIONS

REM --------------------------------------------------
REM CONFIG
REM --------------------------------------------------
set SRC=C:\miratv_ingest\raw_store_db
set DONE=C:\miratv_ingest\processed

set USER=automated
set PASS==tS8nA4yb8]~
set HOST=miratv.club

set TELEMETRY_URL=https://miratv.club/api/telemetry_upload.php
set RUN_ID=%RUN_ID%

REM --------------------------------------------------
REM PROCESS FILES
REM --------------------------------------------------
for %%F in ("%SRC%\*.json") do (
    echo Uploading %%~nxF

    set START_TIME=%TIME%

    curl.exe -s -T "%%F" ftp://%HOST%/raw_store_db/%%~nxF --user %USER%:%PASS%
    if errorlevel 1 (
        echo Upload FAILED: %%~nxF

    
        exit /b 1
    )

    move "%%F" "%DONE%\" >nul

    powershell -NoProfile -Command ^
      "$start=[datetime]'%DATE% %START_TIME%'; $end=Get-Date; $ms=[int]($end-$start).TotalMilliseconds; Invoke-RestMethod -Uri '%TELEMETRY_URL%' -Method Post -ContentType 'application/json' -Body (@{ run_id='%RUN_ID%'; file_name='%%~nxF'; file_size=(Get-Item '%%F').Length; upload_ms=$ms; status='SUCCESS'; transport='ftp'; source='db_grinder_upload_bat' } | ConvertTo-Json)"
)

echo Done.
exit /b 0

