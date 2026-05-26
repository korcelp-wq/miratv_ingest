Write-Host "[05] RAW INGEST PASS 2 TRIGGER"

Invoke-WebRequest `
  -Uri "https://miratv.club/_workers/ingest_series run_two.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" `
  -UseBasicParsing `
  -TimeoutSec 60

Write-Host "[05] RAW INGEST PASS 2 COMPLETE"
exit 0
