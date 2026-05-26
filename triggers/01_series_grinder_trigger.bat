@echo off
setlocal EnableExtensions EnableDelayedExpansion

echo =========================================
echo [01] MiraTV Series Grinder – MASTER
echo =========================================

call powershell -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_grinder.ps1"
if errorlevel 1 exit /b 1

call powershell -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_grinder_2_series_ext.ps1"
if errorlevel 1 exit /b 1

call powershell -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_grinder_3_seasons.ps1"
if errorlevel 1 exit /b 1

call powershell -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_grinder_4_season_ext.ps1"
if errorlevel 1 exit /b 1

call powershell -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_grinder_5_episodes.ps1"
if errorlevel 1 exit /b 1

call powershell -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_grinder_6_cleaner.ps1"
if errorlevel 1 exit /b 1

echo =========================================
echo [01] SERIES GRINDER COMPLETE
echo =========================================

endlocal
exit /b 0
