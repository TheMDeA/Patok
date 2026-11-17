# Patok v1.1.0

DXF drawings that wouldn't show, plus a random render crash — fixed.
Plus a full code audit: dozens of fixes for library safety, imports,
DXF correctness, and battery use.

## What's new
- DXF drawings with many entities now appear on the map (large drawings
  are split into chunks that fit the map channel)
- DXF import now warns when the drawing's coordinates don't look like
  UTM eastings (e.g. a local mine grid), instead of silently placing it
  in the wrong location
- Fixed a random "page(s) failed to render" error (Source already
  exists): overlapping map refreshes no longer race on the same source
- A damaged library entry no longer wipes the whole library, and saves
  are crash-safe
- Maps with a damaged page now import the good pages instead of failing
  outright; TerraGo maps with text-encoded coordinates now import
- DXF drawings render more faithfully: nested blocks, curves, splines,
  full text labels, real text sizes, and hidden layers stay hidden
- GPS stops when the map isn't in use, saving battery; large DXF
  imports no longer freeze the app
- Track recording now keeps going when the phone locks
- Update downloads are verified before installing, can be cancelled,
  and no longer fail silently; a debug-signed release can no longer be
  published by mistake
- Sharing a large map into Patok no longer freezes the app
