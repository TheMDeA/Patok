# Changelog

All notable changes to Patok are documented here. Entries are user-facing
and concise.

## [1.1.0] - 2026-11-17

### Fixed
- Fixed a random "page(s) failed to render" error (Source already
  exists): overlapping map refreshes no longer race on the same source
- DXF import now warns when the drawing's coordinates don't look like
  UTM eastings (e.g. a local mine grid), instead of silently placing it
  in the wrong location
- DXF drawings with many entities now appear on the map (large drawings
  are split into chunks that fit the map channel); a drawing that still
  fails to display now shows a message instead of failing silently
- A damaged entry in the library no longer wipes the whole library —
  bad entries are skipped and the rest are kept; library, waypoint,
  and measurement files are now saved safely, so a crash while saving
  can't corrupt them
- Deleting a map or drawing can no longer destroy the only copy if the
  backup step fails; a failed delete or restore now says so instead of
  silently losing the file
- Saved local grids are no longer wiped out by one damaged entry, and a
  grid built from two identical real-world points is now rejected
  instead of collapsing the drawing to a point
- A map with one damaged page no longer blocks the whole import — the
  good pages still load, and skipped pages are named; a map with a
  broken coordinate system now fails with a clear error instead of
  landing in the wrong place
- TerraGo maps that store their positioning numbers as text now import
  instead of failing; small maps no longer get their positioning misread
- Drawings with bad coordinates, unusual characters, or encodings no
  longer fail the whole import, and failed imports no longer leave
  orphan files behind
- Nested drawing blocks now appear, and blocks with an offset base
  point land in the right place; separate filled areas in a hatch now
  show as separate shapes instead of disappearing
- Curved polylines now show their curves, spline drawings appear
  instead of being skipped, and multi-line text labels show in full
  without formatting codes
- Map labels now use their real text size, and layers switched off in
  the CAD file stay hidden
- The UTM zone you pick is kept when you return from picking a point on
  the map; saving a grid with an existing name now asks before
  replacing it
- DXF drawings keep their opacity on lines, points, and labels after
  reopening the map; very long contour lines no longer break the map
  overlay
- Layers-sheet toggles no longer clash with map refreshes, fixing
  random "source already exists" render failures; opening a drawing
  now tells you if the map isn't ready instead of doing nothing
- Drawings with broken or collapsed extents no longer crash the zoom —
  you get a message instead
- Waypoints and tracks can no longer be saved with an empty name, and
  measurements no longer share the same name; a failed save now reports
  an error instead of failing silently
- GPS now stops when the map isn't in use, saving battery; the
  satellite count now appears on first launch instead of only after a
  restart
- Opening a map you've already opened is instant instead of
  re-rendering, and returning to the map only re-renders what actually
  changed
- The Storage screen now counts DXF drawings and their caches in the
  total, and the library loads faster without starting every map
  preview at once
- Track recording now keeps recording while the phone is locked, with a
  notification showing that a track is being recorded
- A download that stops halfway no longer bricks the update — it is
  detected and re-downloaded instead of being treated as finished, and
  a download can now be cancelled from the update sheet
- A stalled update download no longer hangs forever; a failed update
  check no longer hides updates for a whole day
- The update sheet now tells you when an install was cancelled instead
  of claiming success, and explains the unknown-sources step instead of
  showing a failure
- Files shared to Patok from another app now copy in the background, so
  large maps no longer freeze the app; a failed share now says so,
  sharing several files at once works, and the library no longer
  imports the same shared file twice after the app restarts
- A release build accidentally signed with debug keys can no longer be
  published — the build now fails the release instead

### Performance
- Importing large DXF drawings no longer freezes the app — parsing and
  projection run in the background
- The map screen no longer rebuilds on every GPS fix, and the track
  line updates at most once a second while recording, so long tracks
  stay smooth
- CAD-layer toggles update instantly instead of re-sending the whole
  drawing
- Large map files decode faster and use less memory while opening;
  waypoint averaging is faster on long sessions and map previews
  encode faster with less memory
- Update downloads report progress less often, so the sheet stays
  smooth, and the shown download speed is now the real rate on resumed
  downloads
- Large DXF drawings now import with far less memory — the file is read
  and parsed as a stream instead of being loaded whole several times
  over

## [1.0.5] - 2026-10-18

### Added
- DXF drawing import: bring in mine plan DXFs using UTM coordinates or
  a named local mine grid calibrated from two reference points (GPS,
  map pick, or lat/lon); drawings render as vector overlays with
  per-CAD-layer toggles in the layers sheet and TEXT labels
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
- Library cards have an "Add to overlay" (+) button to stack a map onto
  the current view without opening it solo

### Changed
- Opening a map (from the library or after import) now shows just that
  map instead of stacking over the previously visible ones; use the
  layers sheet to overlay multiple maps

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
