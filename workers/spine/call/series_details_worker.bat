@echo off
set TOKEN=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY
set BASE_URL=https://miratv.club/_ingest
set USERNAME=Marina2025
set PASSWORD=3KY586YR

:loop
echo ----------------------------------------
echo Checking next series...

curl.exe -s "%BASE_URL%/get_next_series.php" ^
  -H "X-Ingest-Token: %TOKEN%" ^
  -o next_series.json

findstr /C:"\"done\":true" next_series.json >nul
if %errorlevel%==0 (
    echo All series processed. Exiting.
    goto end
)

for /f "tokens=2 delims=:," %%A in ('findstr "series_id" next_series.json') do (
    set SERIES_ID=%%~A
)

set SERIES_ID=%SERIES_ID:"=%

echo Processing series ID: %SERIES_ID%

curl.exe -s ^
  "http://uxurwymd.silvervpn.net:8080/player_api.php?username=%USERNAME%^&password=%PASSWORD%^&action=get_series_info^&series_id=%SERIES_ID%" ^
  -o series_info.json

curl.exe -s -X POST "%BASE_URL%/import_series_info.php" ^
  -H "X-Ingest-Token: %TOKEN%" ^
  -H "Content-Type: application/json" ^
  --data-binary "@series_info.json"

echo Done series %SERIES_ID%
timeout /t 60 >nul
goto loop

:end
echo COMPLETE
pause

