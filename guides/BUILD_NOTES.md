# Build Notes (Phases 1–8 Applied)

- URLs updated to:
  XTREAM_BASE_URL = https://cpanel.miratv.club/
  PANEL_BASE_URL  = https://panel.miratv.club/

- Added data models: LiveCategory, LiveChannel, VodCategory, VodItem, SeriesCategory, SeriesItem, AccountInfo
- Extended XtreamApi with live/vod/series categories and simple EPG endpoint
- Added XtreamRepository to fetch data using saved credentials
- PlayerActivity now attempts to build real HLS URLs using username/password + stream_id
- Adult mode persisted with AdultModeManager; 7x HOME toggles state with a Toast
- PIN manager exists; gating to be applied on channel selection UI
- EPG overlay remains as scaffold; replace with real EPG via XtreamRepository.epgFor(stream_id)

## Next UI tasks (recommended)
1) Implement Channel List screen (RecyclerView) to display live channels with logos and favorite/star toggle.
2) From Channel List, on item click:
   - If adult mode is OFF and channel seems adult, hide or require PIN via PinManager.
   - Start PlayerActivity with the selected stream URL and index.
3) Implement Favorites screen using FavoritesRepository.all().
4) Implement EPG overlay using real data for the selected stream.
