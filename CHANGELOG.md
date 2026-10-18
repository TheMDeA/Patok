# Changelog

All notable changes to Patok are documented here. Entries are user-facing
and concise.

## [Unreleased]

## [1.0.5] - 2026-10-18

### Added
- Follow-me mode: the GPS button now keeps the map centered on your
  position while you move; tap again or pan manually to stop
- Reset-north button: snaps the map rotation back to north-up
- Measure panel now lists each leg's distance, not just the total
- Live recording pill on the map: shows REC time and point count while
  a track records, tap to jump to the Field tab
- Library cards show each map's file size
- Undo delete: deleting a map, waypoint, or measurement now offers
  Undo in a snackbar
- Haptic feedback when placing waypoints and measure points

## [1.0.4] - 2026-10-18

### Added
- Crosshair placement mode: a center crosshair with one-tap buttons to
  drop measure points and waypoints exactly at the screen center
- Storage manager in Settings: per-map disk usage with one-tap clearing
  of cached previews
- Compass calibration nudge: a one-time hint to wave the phone in a
  figure-8 when heading accuracy is poor
- Tapping a waypoint pin on the map now opens a detail sheet with
  its name, note, coordinates, and Center/Rename/Delete actions

### Fixed
- Field tab now refreshes when switching to it, so waypoints added from
  the map show up immediately
- Files shared to Patok (e.g. from WhatsApp) now keep their original
  filename in the library instead of "shared_<number>"
- Detail rendering is faster: the PDF stays open between renders, pages
  render in parallel, and rapid pans settle before re-rendering

### Performance
- Map annotations no longer re-read waypoints/measurements from disk on
  every pan/zoom — only the grid redraws on camera idle
- Track recording updates just the track line per GPS fix instead of
  rebuilding all annotations
- Library thumbnails no longer restart their load on every list rebuild

## [1.0.3] - 2026-10-18

### Added
- "Open with Patok": import a PDF shared from another app (e.g. WhatsApp)
  straight into the library
- Library cards now show a thumbnail preview of each map

### Fixed
- Sharp detail rendering now actually engages when zoomed in (it was
  reading a frozen camera position and never triggered)
- Scale bar shows the correct distance (it could read "200 km" while
  zoomed into a mine pit)
- UTM grid spacing follows the actual visible area
- GPS status details stay on a single line
- Update downloads resume after a dropped connection instead of
  restarting from zero

## [1.0.2] - 2026-10-18

### Added
- Sharp text when zoomed in: map detail re-renders at screen resolution
  past a zoom threshold (toggle in Settings)
- GPS status bar under the coordinates: elevation, horizontal/vertical
  accuracy, live satellite count, speed, and fix age, with a copy button
- Area measurement: the measure tool now shows polygon area (m²/ha)
  with a filled preview, saved with the measurement
- Dynamic scale bar on the map
- In-app update checker: check for updates in Settings, with optional
  daily auto-check and one-tap APK download/install
- Waypoint averaging: stand still to average GPS fixes for a precise
  waypoint, with live precision estimate
- Map info panel: per-map georeferencing method, coordinate system,
  page size, and bounds from the Library

### Fixed
- Waypoints and saved measurements now appear on the map (map
  overlays no longer draw over them)
- Bottom coordinate bar now shows your GPS position instead of the map
  center (it could show a stale default location)
- Added the missing INTERNET permission (release builds need it for
  map tiles and the update checker)

## [1.0.1] - 2026-10-15

### Added
- Bottom navigation (Map | Library | Field) like the approved mockup;
  the app now opens on the Library instead of the map
- Map library redesigned: search, "Bring your own map" import card,
  quick filters (Recent / Downloaded / Favorites) with favorite stars
- Field tools redesigned as a launcher (My location, Add waypoint,
  Measure, Record track); new GPS track recording with live track
  on the map, saved to measurements
- UTM grid toggle in the Layers sheet (zoom-adaptive grid)

### Fixed
- Imported maps now land in the right place and orientation
  (georeferencing corrections for Avenza-style PDFs)
- Map camera zooms to a map right after import
- Waypoints and saved measurements now appear on the map
- Sunlight mode applies immediately, no restart needed
- Toggling layer visibility/opacity no longer re-renders the map

## [1.0.0] - 2026-10-14

First public release.

### Added
- Import georeferenced maps (PDF) and display them as overlays on the map
- Offline-first map workspace with live GPS position
- Map library to organize imported maps
- Layer controls: show/hide, opacity, zoom-to-map
- Distance measurement with saved measurements
- GPS waypoints
- Field tools screen
- Coordinate readout in UTM or latitude/longitude
- Settings: sunlight-readable mode, render quality (DPI), coordinate format
