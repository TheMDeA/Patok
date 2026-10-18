# Patok v1.0.4

Faster sharp-detail rendering when zoomed in, plus placement and
maintenance tools.

## What's new
- Crosshair placement mode: a center crosshair with one-tap buttons to
  drop measure points and waypoints exactly at the screen center
- Storage manager in Settings: per-map disk usage with one-tap clearing
  of cached previews
- Compass calibration nudge: a one-time hint to wave the phone in a
  figure-8 when heading accuracy is poor
- Detail rendering is faster: the PDF stays open between renders instead
  of being re-parsed every time, pages render in parallel, and rapid
  pans settle briefly before re-rendering
- Tapping a waypoint pin on the map now opens a detail sheet with
  its name, note, coordinates, and Center/Rename/Delete actions
- Field tab refreshes when switching to it, so waypoints added from the
  map show up immediately
- Smoother map performance: annotations no longer reload from disk on
  every pan/zoom, and track recording redraws only the track line
- Files shared to Patok (e.g. from WhatsApp) now keep their original
  filename in the library instead of "shared_<number>"
