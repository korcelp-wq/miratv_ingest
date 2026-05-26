@echo off
echo =========================================
echo MiraTV Series Details Worker
echo =========================================

cd /d C:\miratv_ingest

powershell -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_details_worker.ps1"


echo =========================================
echo End of MiraTV Series Details Worker
=========================================
