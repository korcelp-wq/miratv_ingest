@echo off
setlocal EnableExtensions EnableDelayedExpansion

echo =========================================
echo MiraTV MASTER RUNNER LOOP START
echo =========================================

:LOOP_START

echo.
echo [LOOP] Requesting next series from server...

REM --------------------------------------------------
REM Ask server for next series (lock issued server-side)
REM --------------------------------------------------
call pwsh -NoProfile -ExecutionPolicy Bypass -File C:\miratv_ingest\triggers\00_series_pipeline_trigger.ps1

if errorlevel 1 (
    echo [LOOP] No series available or server declined lock.
    goto LOOP_END
)

REM --------------------------------------------------
REM Run canonical single-series pipeline
REM --------------------------------------------------
echo.
echo [LOOP] Running master runner for one series...
call C:\miratv_ingest\master_runner2.bat

if errorlevel 1 (
    echo [LOOP] Master runner failed. Stopping loop.
    goto LOOP_END
)

REM --------------------------------------------------
REM Cooldown (IO + FS settle)
REM --------------------------------------------------
echo.
echo [LOOP] Waiting before next iteration...
timeout /t 10 /nobreak >nul

goto LOOP_START

:LOOP_END
echo.
echo =========================================
echo MiraTV MASTER RUNNER LOOP COMPLETE
echo =========================================
endlocal
exit /b 0
