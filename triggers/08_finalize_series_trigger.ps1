Write-Host "[08] FINALIZE SERIES TRIGGER"

Invoke-WebRequest `
  -Uri "https://miratv.club/_workers/finalize_series.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" `
  -UseBasicParsing `
  -TimeoutSec 60

Write-Host "[08] FINALIZE COMPLETE"
exit 0
