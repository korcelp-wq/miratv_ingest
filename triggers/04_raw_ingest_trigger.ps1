Write-Host "[04] RAW INGEST TRIGGER"

Invoke-WebRequest `
  -Uri "https://miratv.club/_workers/ingest_series_files.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" `
  -UseBasicParsing `
  -TimeoutSec 60

Write-Host "[04] RAW INGEST COMPLETE"
exit 0
