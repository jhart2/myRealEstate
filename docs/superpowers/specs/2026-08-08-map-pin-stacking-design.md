# Map pin stacking for shared coordinates

## Goal
When two or more search-map price pills share the exact same lat/lng, show them stacked vertically instead of overlapping so each listing stays visible and clickable.

## Scope
- Client-only change in `app/javascript/controllers/search_map_controller.js` (`renderMarkers`)
- Exact coordinate match only (string key of existing `lat` + `lng` values)
- Always-visible vertical stack (no hover/click expand)

## Design
- Group listings by exact `lat,lng` before creating Leaflet markers
- Index `0` stays at the true point; index `n` shifts the pill **up** by `n × STACK_PX` (~30px) via marker icon offset / CSS translate — **do not change stored lat/lng**
- Raise `zIndexOffset` with stack index so upper pills remain clickable
- Popup `offset` tracks the same vertical shift so the card still anchors to its pill
- Pan / `activateListing` continue to use the listing’s real coordinates
- Stacking re-applies whenever `renderMarkers()` runs (filter reload, viewport reload, currency refresh)

## Out of scope
- Near-miss / rounded coordinate clustering
- Spiderfy / explode-on-click
- Marker clustering plugins
- Server-side coordinate nudging or geocode fixes
