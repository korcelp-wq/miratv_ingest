@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM --------------------------------------------------
REM MiraTV — EPG Convert Trigger (BATCH)
REM --------------------------------------------------

echo.
echo [EPG] Trigger start

call C:\miratv_ingest\workers\spine\call\import_epg.bat

if errorlevel 1 goto FAIL

echo ✅ STEP 4.0 COMPLETE

if errorlevel 1 goto FAIL


