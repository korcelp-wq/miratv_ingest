##curl.exe -X POST -F "epg=@epg.xml" https://miratv.club/_ingest/import_epg.php

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EpgFile = Join-Path $ScriptDir "..\export\epg.xml"
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$path = "https://miratv.club/_ingest/import_epg.php"

curl.exe -X POST -H "X-INGEST-TOKEN: $token" -F "epg=@$EpgFile" $path
