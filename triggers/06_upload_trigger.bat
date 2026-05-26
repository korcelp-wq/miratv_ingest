@echo off
setlocal

echo [06] UPLOAD TRIGGER START

for %%F in (C:\miratv_ingest\series_sep\*.json) do (
    curl.exe -T "%%F" ftp://miratv.club/raw_store/%%~nxF --user automated:=tS8nA4yb8]~
    move "%%F" C:\miratv_ingest\processed\
)

echo [06] UPLOAD COMPLETE
endlocal
exit /b 0