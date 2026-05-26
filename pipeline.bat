@echo off
echo =========================================
echo MiraTV Series Details Worker
echo =========================================

cd /d C:\miratv_ingest

powershell -ExecutionPolicy Bypass -File "C:\miratv_ingest\pipeline.ps1"

pause
