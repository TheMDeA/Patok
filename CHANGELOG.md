# Changelog

All notable changes to Patok are documented here. Entries are user-facing
and concise.

## [Unreleased]

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
