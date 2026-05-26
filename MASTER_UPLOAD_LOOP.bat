@echo off
setlocal EnableExtensions EnableDelayedExpansion

set ACCESSORY_PS=C:\miratv_ingest\_workers\_accessories.psm1
set COMPONENT=master_accessory_loop

echo =========================================
echo      MiraTV MASTER UPLOAD LOOP START
echo =========================================

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'LOOP_START' '%COMPONENT%'"

:LOOP_START

echo.
echo [LOOP] Running master runner for AI Accessories ...
call C:\miratv_ingest\telemetry_stage.bat
call C:\miratv_ingest\master_runner_loop_acc.bat

if errorlevel 1 (
    call pwsh -NoProfile -Command ^
      "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'SERIES_RUN_FAILED' '%COMPONENT%'; Emit-Lake 'FAILURE' '%COMPONENT%'"
    goto LOOP_END
)

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'SERIES_RUN_SUCCESS' '%COMPONENT%'; Emit-Lake 'SUCCESS' '%COMPONENT%'"

echo.
echo [LOOP] Waiting 15 minutes before next iteration...
timeout /t 900 /nobreak >nul

goto LOOP_START

:LOOP_END

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'LOOP_END' '%COMPONENT%'"

echo.
echo =========================================
echo MiraTV MASTER UPLOAD LOOP COMPLETE
echo =========================================
endlocal
exit /b 0

