@echo off
set USER=automated
set PASS==tS8nA4yb8]~
set HOST=miratv.club
set FILE=C:\miratv_ingest\export\epg.xml

curl -T "%FILE%" ftp://%HOST%/epg.xml --user %USER%:%PASS%

pause
