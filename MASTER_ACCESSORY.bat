@echo off
setlocal EnableExtensions EnableDelayedExpansion

set ACCESSORY_PS=C:\miratv_ingest\_workers\_accessories.psm1
set COMPONENT=master_accessory

echo =========================================
echo MiraTV MASTER ACCESSORY UPLOAD LOOP START
echo =========================================

call pwsh -NoProfile -Command ^
  "Import-Module '%ACCESSORY_PS%'; Emit-Ops 'LOOP_START' '%COMPONENT%'"

REM --------------------------------------------------
REM STEP 01 — Upload IMG info
REM --------------------------------------------------
 echo.
 echo [01] Uploading series artifacts
call "C:\miratv_ingest\triggers\img_upload_trigger.bat"
 if errorlevel 1 goto FAIL

 echo ✅ STEP 01 COMPLETE

REM --------------------------------------------------
REM STEP 02 — Upload statistics
REM --------------------------------------------------
 echo.
 echo [02] Uploading statistics
call "C:\miratv_ingest\triggers\lake_upload_trigger.bat"
 if errorlevel 1 goto FAIL

 echo ✅ STEP 02 COMPLETE

REM --------------------------------------------------
REM STEP 03 — Upload errors
REM --------------------------------------------------
 echo.
 echo [03] Uploading errors
call "C:\miratv_ingest\triggers\ops_upload_trigger.bat"
 if errorlevel 1 goto FAIL

 echo ✅ STEP 03 COMPLETE


REM --------------------------------------------------
REM STEP 04 — ingest IMG info 
REM --------------------------------------------------
  echo.
  echo [STEP 04] img_ingest_trigger.ps1
  echo --------------------------------------------------
  call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\img_ingest_trigger.ps1"
  if errorlevel 1 goto STOP

  echo ✅ STEP 4 COMPLETE

REM --------------------------------------------------
REM STEP 05 - ingest statistic
REM --------------------------------------------------

  echo.
  echo [STEP 05] lake_ingest_trigger.ps1
  echo --------------------------------------------------
  call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\lake_ingest_trigger.ps1"

  if errorlevel 1 goto STOP
  echo ✅ STEP 5 COMPLETE


REM --------------------------------------------------
REM STEP 06 - ingest errors 
REM --------------------------------------------------

  echo.
  echo [STEP 06] 9episode_resolver_trigger.ps1
  echo --------------------------------------------------
  call pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\ops_ingest_trigger.ps1"
  if errorlevel 1 goto STOP
  echo ✅ STEP 06 COMPLETE
