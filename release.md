# Patok v1.0.7

DXF drawings that wouldn't show, plus a random render crash — fixed.

## What's new
- DXF drawings with many entities now appear on the map (large drawings
  are split into chunks that fit the map channel)
- DXF import now warns when the drawing's coordinates don't look like
  UTM eastings (e.g. a local mine grid), instead of silently placing it
  in the wrong location
- Fixed a random "page(s) failed to render" error (Source already
  exists): overlapping map refreshes no longer race on the same source
