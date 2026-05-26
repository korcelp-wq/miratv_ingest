@echo off
setlocal

echo [EPG] Trigger start

curl.exe -X POST "https://miratv.club/_ingest/import_epg.php" ^
  -H "X-Ingest-Token: WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" ^
  -F "epg=@C:\miratv_ingest\raw\epg.xml"

if errorlevel 1 goto FAIL

echo EPG TRIGGER COMPLETE
exit /b 0