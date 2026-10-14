# Patok

Offline georeferenced map reader for Android — import a georeferenced map,
see it on the map with your GPS position, measure distances, and drop
waypoints. Avenza-style, built with Flutter.

> *Patok* — the survey stake hammered into the ground. Every surveyor knows it.

## Stack

| Piece | Package | Notes |
|---|---|---|
| Map | `maplibre_gl` 0.27.1 | BSD, offline-first, image overlays |
| PDF rendering | `pdfrx` 2.6.5 (PDFium) | MIT, page → PNG at any DPI |
| Reprojection | `proj4dart` 3.0.0 | MIT, OGC/ESRI WKT + proj strings |
| Georef parsing | `lib/src/geopdf/` (hand-written) | No dependency, no GPL |
| GPS | `geolocator` | Works fully offline |
| File picking | `file_picker` | System picker, no storage perm needed |

All licenses are permissive (MIT/BSD/Apache-2.0).

## What the parser reads

`lib/src/geopdf/` is a minimal PDF parser (xref tables **and** xref streams,
object streams, FlateDecode with PNG/TIFF predictors) plus a georeferencing
extractor supporting both real-world encodings:

- **OGC/Adobe style** — page `/VP` viewport → `/Measure /Subtype /GEO`
  (`/GPTS` lon/lat + `/LPTS` page coords, affine least-squares fit)
- **TerraGo style** — page `/LGIDict` with `/CTM` (preferred) or
  `/Registration` quadruples + `/Projection /WKT` (reprojected via PROJ)

Covered by `test/geopdf_test.dart` (synthetic PDFs for both styles,
compressed-xref round trip, affine/pixel-mapping math). Run with
`flutter test`.

## Project layout

```
lib/
  main.dart                  App entry + service wiring
  src/
    theme.dart               Field-dark theme, hi-vis orange accent
    models.dart              GeoMap, PageGeoref, Waypoint, Measurement
    geopdf/
      pdf_model.dart         Minimal PDF object model
      pdf_parser.dart        xref/object parser
      georef.dart            Extractor, affine fit, pixel mapping, UTM
    services.dart            MapLibrary, ImportService, RenderService,
                             LocationService, SettingsService, FieldDataStore
    ui/
      map_screen.dart        Map workspace (overlays, layers sheet, measure)
      library_screen.dart    Imported maps
      import_screen.dart     Import flow with progress
      tools_screen.dart      Waypoints + measurements
      settings_screen.dart   Sunlight mode, DPI, coordinate format
assets/
  map_style.json             Minimal offline dark basemap style
```

## Import pipeline

1. Pick a PDF → copied to app storage (`maps/<id>.pdf`)
2. `PdfParser` reads the xref + document catalog (lazy — only the
   dictionaries needed, so even 500 MB files parse fast)
3. `GeorefExtractor` pulls `/VP /Measure` or `/LGIDict` per page
4. Page corners are computed in WGS84 and stored; the map screen renders
   each visible page with pdfrx at the configured DPI and adds it as a
   MapLibre image source + raster layer

Large pages are capped at 4096 px on the long edge (GL texture limit).
v2: pre-render a tile pyramid at import (Avenza-style) instead of a
single overlay.

## Android notes

- Android-only (`--platforms=android`); `applicationId com.dmda.fieldatlas`
- Permissions: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`
- The bundled `map_style.json` is an empty offline style — add an offline
  tile source (MBTiles/PMTiles) for a real basemap

## Verification

- `flutter analyze` — clean
- `flutter test` — 10/10 pass
- APK builds need a real machine/CI (Gradle daemon can't run in a sandbox)
