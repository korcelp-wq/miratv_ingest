@echo off
setlocal EnableExtensions EnableDelayedExpansion

set SRC=C:\miratv_ingest\igm_spool
set DONE=C:\miratv_ingest\processed
set TMP=C:\miratv_ingest\TMP


REM --------------------------------------------------
REM Ensure directories exist
REM --------------------------------------------------
if not exist "%TMP%"  mkdir "%TMP%"
if not exist "%DONE%" mkdir "%DONE%"

REM --------------------------------------------------
REM FTP Credentials
REM --------------------------------------------------

set USER=automated
set PASS==tS8nA4yb8]~
set HOST=miratv.club

REM --------------------------------------------------
REM Move new OPS files to temp
REM --------------------------------------------------

for %%F in (%SRC%\img*.log) do (
    echo Moving %%~nxF to temp directory
    move "%%F" "%TMP%\"
)

REM --------------------------------------------------
REM Uploading  files To server 
REM --------------------------------------------------

for %%F in (%TMP%\img*.log) do (
    echo Uploading %%~nxF

    curl.exe -T "%%F" ftp://%HOST%/img/%%~nxF --user %USER%:%PASS%

    if errorlevel 1 (
        echo ❌ Upload failed for %%~nxF
        echo Leaving file in TMP for retry
        exit /b 1
    )

    echo ✅ Uploaded %%~nxF
    move "%%F" "%DONE%\" >nul
)


echo Done.
exit /b 0

