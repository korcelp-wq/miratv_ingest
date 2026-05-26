@echo off
setlocal EnableExtensions EnableDelayedExpansion

set ACCESSORY_PS=C:\miratv_ingest\_workers\_accessories.psm1
set COMPONENT=master_runner_loop

echo =========================================
echo MiraTV MASTER RUNNER LOOP START
echo =========================================

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'LOOP_START' '%COMPONENT%'"

:LOOP_START

echo.
echo [LOOP] Requesting next series from server...


call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Lake 'SERIES_LOCK_ACQUIRED' '%COMPONENT%'"

echo.
echo [LOOP] Running master runner for one series...
call C:\miratv_ingest\master_runner2.bat

if errorlevel 1 (
    call pwsh -NoProfile -Command ^
      "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'SERIES_RUN_FAILED' '%COMPONENT%'; Emit-Lake 'FAILURE' '%COMPONENT%'"
    goto LOOP_END
)

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'SERIES_RUN_SUCCESS' '%COMPONENT%'; Emit-Lake 'SUCCESS' '%COMPONENT%'"

echo.
echo [LOOP] Waiting before next iteration...


goto LOOP_START

:LOOP_END

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'LOOP_END' '%COMPONENT%'"

echo.
echo =========================================
echo MiraTV MASTER RUNNER LOOP COMPLETE
echo =========================================
endlocal
exit /b 0
