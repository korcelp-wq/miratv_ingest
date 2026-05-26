$BASE  = "https://miratv.club/_workers"
$TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"


while ($true) {
   


  #0) Fetch Series ID
  powershell -File C:\miratv_ingest\triggers\series_pipeline_trigger.ps1 `
    -SeriesId $SID `
    -ProviderSeriesId $PID

  # 1) Fetch payload
  powershell -File C:\miratv_ingest\triggers\series_details_fetch.ps1 `
    -SeriesId $SID `
    -ProviderSeriesId $PID

  # 2) Upload raw
  powershell -File C:\miratv_ingest\triggers\raw_ingest_trigger.ps1
    -SeriesId $SID `
    -ProviderSeriesId $PID

  # 3) Normalize
  powershell -File C:\miratv_ingest\triggers\normalize_trigger.ps1`
    -SeriesId $SID `
    -ProviderSeriesId $PID

  # 4) Resolve episodes
    powershell -File C:\miratv_ingest\triggers\episode_resolver.php
    -SeriesId $SID `
    -ProviderSeriesId $PID


      #-1) get series ID
  powershell -ExecutionPolicy Bypass -File "C:\miratv_ingest\series_details_worker.ps1"
  
   }
 