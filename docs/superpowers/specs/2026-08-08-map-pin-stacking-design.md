# Map pin stacking for shared coordinates

## Goal
When two or more search-map price pills share the exact same lat/lng, avoid unreadable overlap: stack them when zoomed in, collapse to the most relevant listing when zoomed out.

## Scope
- Client-only change in `app/javascript/controllers/search_map_controller.js` (`renderMarkers` + zoom handling)
- Exact coordinate match only (string key of existing `lat` + `lng` values)

## Design
- Group listings by exact `lat,lng` before creating Leaflet markers
- **Zoom ≥ 15:** fan the group upward (`n × STACK_PX` ≈ 30px) via `iconAnchor` — stored lat/lng stay true
- **Zoom < 15:** show only the most relevant pin for that point (first in `listingsValue` / current search sort); hide the rest (`opacity: 0`, non-interactive)
- Selecting a buried listing from the list (while collapsed) temporarily surfaces that listing’s pill for the point
- Raise `zIndexOffset` with stack index so stacked pills remain clickable
- Popup `offset` tracks the same vertical shift so the card still anchors to its pill
- Re-apply on `zoomend` and whenever `renderMarkers()` runs

## Out of scope
- Near-miss / rounded coordinate clustering
- Spiderfy / explode-on-click
- Marker clustering plugins
- Server-side coordinate nudging or geocode fixes
