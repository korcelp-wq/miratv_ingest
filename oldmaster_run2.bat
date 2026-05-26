@echo off
chcp 65001 > nul
setlocal

echo ==================================================
echo MiraTV MASTER PIPELINE (STEP-BY-STEP UNLOCK)
echo Current unlock: STEP 0 + STEP 1 ONLY (NO LOOP)
echo ==================================================

REM --------------------------------------------------
REM Base paths (adjust if your layout differs)
REM --------------------------------------------------
set BASE=C:\miratv_ingest
set TRIGGERS=%BASE%\triggers
set WORKERS=%BASE%\workers

REM ==================================================
REM STEP 0 — series pipeline allocator (ACTIVE)
REM File: triggers\0series_pipeline_trigger.ps1
REM Purpose: calls server pipeline allocator (lock + next series info)
REM ==================================================
echo.
echo [STEP 0] 0series_pipeline_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\0series_pipeline_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 0 COMPLETE

ENV
REM ==================================================
REM STEP 1 — series details worker (ACTIVE)
REM File: workers\1series_details_worker.bat
REM Purpose: runs series_details_worker.ps1 which fetches series ID itself
REM ==================================================
echo.
echo [STEP 1] 1series_details_worker.bat 
echo --------------------------------------------------
call "%base%\series_details_worker.bat"
if errorlevel 1 goto STOP
echo ✅ STEP 1 COMPLETE

REM ==================================================
REM STEP 2 — parse trigger (LOCKED)
REM File: triggers\2parse_trigger.ps1
REM Purpose: server-side parse stage (file-system driven)
REM ==================================================
echo.
echo [STEP 2] 2parse_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\2parse_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 2 COMPLETE

REM ==================================================
REM STEP 3 — normalize trigger (LOCKED)
REM File: triggers\3normalize_trigger.ps1
REM Purpose: server-side normalize stage
REM ==================================================
echo.
echo [STEP 3] 3normalize_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\3normalize_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 3 COMPLETE

REM ==================================================
REM STEP 4 — RESERVED (LOCKED)
REM Purpose: future modular insert (intentionally empty)
REM ==================================================
echo.
echo [STEP 4] RESERVED (future module)
REM echo --------------------------------------------------
REM REM call "%TRIGGERS%\4_*.bat"
REM REM if errorlevel 1 goto STOP
REM echo ✅ STEP 4 COMPLETE

REM ==================================================
REM STEP 5 — RESERVED (LOCKED)
REM Purpose: future modular insert (intentionally empty)
REM ==================================================
echo.
 echo [STEP 5] RESERVED (future module)
REM echo --------------------------------------------------
REM REM powershell -NoProfile -ExecutionPolicy Bypass -File "%TRIGGERS%\5_*.ps1"
REM REM if errorlevel 1 goto STOP
REM echo ✅ STEP 5 COMPLETE

REM ==================================================
REM STEP 6 — upload trigger (LOCKED)
REM File: triggers\6upload_trigger.bat
REM Purpose: upload raw_store files to server (then move to processed)
REM ==================================================
echo.
echo [STEP 6] 6upload_trigger.bat - 
echo --------------------------------------------------
call "%TRIGGERS%\6upload_trigger.bat"
if errorlevel 1 goto STOP
echo ✅ STEP 6 COMPLETE

REM ==================================================
REM STEP 7 — raw ingest trigger (LOCKED)
REM File: triggers\7raw_ingest_trigger.ps1
REM Purpose: server-side raw ingest from filesystem into DB
REM ==================================================
echo.
echo [STEP 7] 7raw_ingest_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
   -File "%TRIGGERS%\7raw_ingest_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 7 COMPLETE

REM ==================================================
REM STEP 8 — raw table parse trigger (LOCKED)
REM File: triggers\8raw_table_parse_trigger.ps1
REM Purpose: server-side raw table parse / populate details tables
REM ==================================================
echo.
echo [STEP 8] 8raw_table_parse_trigger.ps1
echo --------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\8raw_table_parse_trigger.ps1"
if errorlevel 1 goto STOP
echo ✅ STEP 8 RAW TABLE INGEST — COMPLETE


REM ==================================================
REM STEP 9 — raw table to prod series tables trigger (LOCKED)
REM File: triggers\9materialize_series_trigger.ps1
REM Purpose: server-side raw table parse / populate details tables
echo ==================================================
echo [STEP 9] 9materialize_series_trigger.
echo ==================================================

powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%TRIGGERS%\9materialize_series_trigger.ps1"
if errorlevel 1 goto STOP

echo ==================================================
echo ✅ STEP 9 RAW TABLE PROD TABLE INGEST — COMPLETE
echo ==================================================


REM ==================================================
REM STEP 9 — raw table normalize trigger (LOCKED)
REM File: triggers\9raw_table_normalize_trigger.ps1
REM Purpose: server-side raw table parse / populate details tables
REM ==================================================
REM echo.
REM echo [STEP 9] 9raw_table_normalize_trigger.ps1
REM echo --------------------------------------------------
REM powershell -NoProfile -ExecutionPolicy Bypass ^
REM   -File "%TRIGGERS%\9raw_table_normalize_trigger.ps1"
REM if errorlevel 1 goto STOP
REM echo ✅ STEP 8 COMPLETE


REM ==================================================
REM STEP 10 — episode resolver trigger (LOCKED)
REM File: triggers\9episode_resolver_trigger.ps1
REM Purpose: server-side episode stream resolution
REM ==================================================
REM echo.
REM echo [STEP 9] 9episode_resolver_trigger.ps1
REM echo --------------------------------------------------
REM powershell -NoProfile -ExecutionPolicy Bypass ^
REM   -File "%TRIGGERS%\9episode_resolver_trigger.ps1"
REM if errorlevel 1 goto STOP
REM echo ✅ STEP 9 COMPLETE

echo.
echo ==================================================
echo ✅ MASTER FINISHED (0 + 1 ONLY)
echo ==================================================
exit /b 0

:STOP
echo.
echo ==================================================
echo ❌ MASTER STOPPED ON ERROR
echo ==================================================
exit /b 1
