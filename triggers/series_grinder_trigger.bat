@echo off
echo =========================================
echo MiraTV Series Grinder – MASTER
echo =========================================

call pwsh -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\workers\series_grinder.ps1"

echo =========================================
echo Series Grinder – STEP 1 COMPLETE
echo =========================================

call pwsh -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\workers\series_grinder_2_series_ext.ps1"

echo =========================================
echo Series Grinder – STEP 2 COMPLETE
echo =========================================

call pwsh -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\workers\series_grinder_3_seasons.ps1"

echo =========================================
echo Series Grinder – STEP 3 COMPLETE
echo =========================================

call pwsh -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\workers\series_grinder_4_season_ext.ps1"

echo =========================================
echo Series Grinder – STEP 4 COMPLETE
echo =========================================

call pwsh -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\workers\series_grinder_5_episodes.ps1"

echo =========================================
echo Series Grinder – STEP 5 COMPLETE
echo =========================================

call pwsh -NoProfile -ExecutionPolicy Bypass ^
  -File "C:\miratv_ingest\workers\series_grinder_6_cleaner.ps1"

echo =========================================
echo Series Grinder – STEP 6 COMPLETE
echo =========================================

echo =========================================
echo Series Grinder – ALL STEPS COMPLETE
echo =========================================


echo =========================================
echo Waiting for IO to settle...
timeout /t 3 >nul
echo =========================================
echo Series Grinder – COMPLETE
echo =========================================
