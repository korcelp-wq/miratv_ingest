@echo off

set SRC=C:\miratv_ingest\raw
set DONE=C:\miratv_ingest\processed

set USER=automated
set PASS==tS8nA4yb8]~
set HOST=miratv.club

for %%F in (%SRC%\*.json) do (
    echo Uploading %%~nxF

    curl.exe -T "%%F" ftp://%HOST%/spine/%%~nxF --user %USER%:%PASS%

    move "%%F" "%DONE%\"
)

echo Done.

