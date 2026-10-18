import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

import 'app_scope.dart';
import '../models.dart';
import '../services.dart';
import '../geopdf/georef.dart';
import '../theme.dart';

/// Map workspace: full-bleed MapLibre map with imported georeferenced
/// PDF pages as image overlays, GPS, layers sheet, measure mode and a
/// coordinate readout bar.
///
/// Lives inside [HomeScreen]'s tab stack; cross-tab actions (open map,
/// start measure, go to GPS) go through the public methods below.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.onBrowseMaps});

  /// Called when the user taps the empty-state button (no maps yet).
  final VoidCallback? onBrowseMaps;

  @override
  State<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends State<MapScreen> {
  MapLibreMapController? _controller;
  String? _styleJson;
  bool _busy = false;
  String? _status;

  final Set<String> _sourceIds = {};
  final Set<String> _layerIds = {};

  // Dirty-checking for tab switches: re-render only when the library
  // or the render DPI changed while the Map tab was hidden.
  int _lastFingerprint = 0;
  double _lastDpi = -1;

  // High-detail overlay: hi-res re-render of the visible region when
  // zoomed in (keeps PDF text sharp like a native viewer).
  static const _detailSrcPrefix = 'patok_src_detail_';
  static const _detailLyrPrefix = 'patok_lyr_detail_';
  final Set<String> _detailLayerIds = {};
  final Set<String> _detailSourceIds = {};
  int _detailGen = 0; // cancels stale in-flight detail renders
  String _detailKey = ''; // page + quantized viewport + zoom bucket
  // Base overlay bitmap width (px) and page top-edge width (meters),
  // per page key: used to decide when the base is being upscaled.
  final Map<String, int> _basePxWidth = {};
  final Map<String, double> _baseMetersWidth = {};

  String _pageKey(GeoMap m, GeoMapPage p) => '${m.id}_${p.pageIndex}';

  // Measure mode.
  bool _measureMode = false;
  final List<LatLng> _measurePoints = [];

  // Coordinate readout.
  String _coordText = '—';
  StreamSubscription<Position>? _posSub;
  Position? _lastGps;

  /// Meters per screen pixel at the current camera; drives the scale bar.
  final ValueNotifier<double> _metersPerPx = ValueNotifier(1000);

  late final TrackRecorder _trackRecorder;
  late final GnssService _gnssService;

  AppScope get _scope => AppScope.of(context);

  @override
  void initState() {
    super.initState();
    _loadStyle();
    _startGps();
    _trackRecorder = AppScope.of(context).trackRecorder;
    _gnssService = AppScope.of(context).gnssService;
    _trackRecorder.livePoints.addListener(_onTrackUpdate);
    _gnssService.satellites.addListener(_onSatellitesChanged);
  }

  void _onTrackUpdate() {
    _redrawAnnotations();
  }

  @override
  void dispose() {
    _trackRecorder.livePoints.removeListener(_onTrackUpdate);
    _posSub?.cancel();
    _gnssService.satellites.removeListener(_onSatellitesChanged);
    _metersPerPx.dispose();
    super.dispose();
  }

  Future<void> _loadStyle() async {
    final s = await rootBundle.loadString('assets/map_style.json');
    if (mounted) setState(() => _styleJson = s);
  }

  Future<void> _startGps() async {
    final ok = await _scope.locationService.ensurePermission();
    if (!ok) return;
    _posSub = _scope.locationService.positionStream().listen((p) {
      _lastGps = p;
      _updateCoordReadout();
    });
  }

  // ------------------------------------------------------------ overlays

  String _sourceId(GeoMap m, GeoMapPage p) => 'fa_src_${m.id}_${p.pageIndex}';
  String _layerId(GeoMap m, GeoMapPage p) => 'fa_lyr_${m.id}_${p.pageIndex}';

  Future<void> _onStyleLoaded() async {
    // A style reload wipes all custom layers/sources: rebuild the
    // annotation stack first so the PDF overlays below can reference it.
    _annLayersReady = false;
    await _ensureAnnotationLayers();
    await _refreshOverlays();
    await _redrawAnnotations();
  }

  Future<void> _refreshOverlays() async {
    final c = _controller;
    if (c == null) return;
    // Annotation layers must exist before raster overlays reference them
    // via belowLayerId (no-op when already ready).
    await _ensureAnnotationLayers();
    // Base overlays changed: any detail render is stale.
    await _clearDetailOverlay();
    _basePxWidth.clear();
    _baseMetersWidth.clear();
    // Remove old overlay layers/sources.
    for (final id in _layerIds) {
      try {
        await c.removeLayer(id);
      } catch (_) {}
    }
    for (final id in _sourceIds) {
      try {
        await c.removeSource(id);
      } catch (_) {}
    }
    _layerIds.clear();
    _sourceIds.clear();

    setState(() {
      _busy = true;
      _status = 'Rendering maps…';
    });
    var failures = 0;
    String? firstError;
    for (final map in _scope.library.maps) {
      if (!map.visible) continue;
      for (final page in map.pages) {
        try {
          await _addOverlay(c, map, page);
        } catch (e) {
          failures++;
          firstError ??= e.toString().replaceFirst('StateError: ', '');
        }
      }
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = failures > 0
            ? '$failures page(s) failed to render'
                  '${firstError != null ? ': $firstError' : ''}'
            : null;
      });
    }
    _lastFingerprint = _libraryFingerprint();
    _lastDpi = _scope.settings.renderDpi;
  }

  Future<void> _addOverlay(
    MapLibreMapController c,
    GeoMap map,
    GeoMapPage page,
  ) async {
    final pdfPath = _scope.library.pdfPath(map);
    final overlay = await _scope.renderService.renderPage(
      pdfPath: pdfPath,
      georef: page.georef,
      dpi: _scope.settings.renderDpi,
    );
    final quad = LatLngQuad(
      topLeft: LatLng(overlay.corners[0].y, overlay.corners[0].x),
      topRight: LatLng(overlay.corners[1].y, overlay.corners[1].x),
      bottomRight: LatLng(overlay.corners[2].y, overlay.corners[2].x),
      bottomLeft: LatLng(overlay.corners[3].y, overlay.corners[3].x),
    );
    _validateQuad(overlay.corners, page);
    final sid = _sourceId(map, page);
    final lid = _layerId(map, page);
    await c.addImageSource(sid, overlay.pngBytes, quad);
    await _addPdfRasterLayer(c, sid, lid, map.opacity);
    _sourceIds.add(sid);
    _layerIds.add(lid);
    // Remember the base bitmap size for the detail-zoom decision.
    final key = _pageKey(map, page);
    _basePxWidth[key] = overlay.width;
    final tl = page.cornerLonLat[0], tr = page.cornerLonLat[1];
    _baseMetersWidth[key] = Geolocator.distanceBetween(
      tl[1],
      tl[0],
      tr[1],
      tr[0],
    );
  }

  /// Adds a PDF raster layer, always *below* the annotation stack so
  /// waypoints/measurements can never be buried by an overlay re-add.
  Future<void> _addPdfRasterLayer(
    MapLibreMapController c,
    String sid,
    String lid,
    double opacity,
  ) async {
    final props = RasterLayerProperties(rasterOpacity: opacity);
    try {
      await c.addRasterLayer(sid, lid, props, belowLayerId: _lyrGrid);
    } catch (_) {
      // Annotation layers not ready: add on top; the next
      // _ensureAnnotationLayers pass restores the order.
      await c.addRasterLayer(sid, lid, props);
    }
  }

  ///
  /// Removes the high-detail overlay for one page (if present).
  Future<void> _removeDetailForPage(GeoMap map, GeoMapPage page) async {
    final c = _controller;
    final sid = '$_detailSrcPrefix${map.id}_${page.pageIndex}';
    final lid = '$_detailLyrPrefix${map.id}_${page.pageIndex}';
    if (!_detailLayerIds.contains(lid) && !_detailSourceIds.contains(sid)) {
      return;
    }
    _detailKey = ''; // force re-evaluation on next idle
    if (c == null) return;
    try {
      await c.removeLayer(lid);
    } catch (_) {}
    try {
      await c.removeSource(sid);
    } catch (_) {}
    _detailLayerIds.remove(lid);
    _detailSourceIds.remove(sid);
  }

  /// Removes the high-detail overlay layers/sources (if any).
  Future<void> _clearDetailOverlay() async {
    final c = _controller;
    _detailKey = '';
    if (c == null) {
      _detailLayerIds.clear();
      _detailSourceIds.clear();
      return;
    }
    for (final id in _detailLayerIds) {
      try {
        await c.removeLayer(id);
      } catch (_) {}
    }
    for (final id in _detailSourceIds) {
      try {
        await c.removeSource(id);
      } catch (_) {}
    }
    _detailLayerIds.clear();
    _detailSourceIds.clear();
  }

  /// Re-renders the visible region at high detail when zoomed in past the
  /// point where the base overlay starts upscaling (text would go blurry).
  /// Runs on camera idle; stale renders are cancelled via [_detailGen].
  Future<void> _maybeUpdateDetailOverlay() async {
    final c = _controller;
    if (c == null) return;
    if (!_scope.settings.detailZoom) {
      await _clearDetailOverlay();
      return;
    }
    final gen = ++_detailGen;
    try {
      final region = await c.getVisibleRegion();
      if (gen != _detailGen) return;
      // Screen meters-per-pixel from the live region — never from the
      // plugin's cached camera position (can go stale; see
      // _metersPerPixel).
      final screenMpp = _metersPerPixel(region);
      if (screenMpp <= 0) return;

      // Collect detail targets for visible pages whose base overlay is
      // being upscaled.
      final targets = <_DetailTarget>[];
      for (final map in _scope.library.maps) {
        if (!map.visible) continue;
        for (final page in map.pages) {
          final key = _pageKey(map, page);
          final basePx = _basePxWidth[key];
          final baseMeters = _baseMetersWidth[key];
          if (basePx == null || baseMeters == null) continue;
          final baseMpp = baseMeters / basePx;
          // Base is sharp while the screen shows it at >= ~0.66x.
          if (screenMpp >= baseMpp / 1.5) continue;
          // Intersect the visible region with the page bbox.
          final corners = page.cornerLonLat;
          final lons = corners.map((p) => p[0]);
          final lats = corners.map((p) => p[1]);
          var minLon = math.max(
            lons.reduce(math.min),
            region.southwest.longitude,
          );
          var maxLon = math.min(
            lons.reduce(math.max),
            region.northeast.longitude,
          );
          var minLat = math.max(
            lats.reduce(math.min),
            region.southwest.latitude,
          );
          var maxLat = math.min(
            lats.reduce(math.max),
            region.northeast.latitude,
          );
          if (maxLon - minLon <= 0 || maxLat - minLat <= 0) continue;
          // Margin so small pans don't immediately re-render.
          final mLon = (maxLon - minLon) * 0.25;
          final mLat = (maxLat - minLat) * 0.25;
          minLon = math.max(lons.reduce(math.min), minLon - mLon);
          maxLon = math.min(lons.reduce(math.max), maxLon + mLon);
          minLat = math.max(lats.reduce(math.min), minLat - mLat);
          maxLat = math.min(lats.reduce(math.max), maxLat + mLat);
          // Target width: region in screen px, supersampled 1.5x.
          final regionMeters = Geolocator.distanceBetween(
            (minLat + maxLat) / 2,
            minLon,
            (minLat + maxLat) / 2,
            maxLon,
          );
          final targetPx = (regionMeters / screenMpp * 1.5).clamp(
            256.0,
            2048.0,
          );
          targets.add(
            _DetailTarget(
              map: map,
              page: page,
              minLon: minLon,
              minLat: minLat,
              maxLon: maxLon,
              maxLat: maxLat,
              targetWidthPx: targetPx,
            ),
          );
        }
      }

      if (targets.isEmpty) {
        if (_detailLayerIds.isNotEmpty) await _clearDetailOverlay();
        return;
      }

      // Quantized key: re-render only on meaningful viewport/zoom change.
      // (Zoom bucket derived from mpp: half-zoom steps like before.)
      final zoomBucket =
          (math.log(1 / screenMpp) / math.ln2 * 2).round();
      final keyBuf = StringBuffer();
      for (final t in targets) {
        final q = (t.maxLon - t.minLon) / 8;
        keyBuf.write(
          '${t.map.id}_${t.page.pageIndex}_'
          '${(t.minLon / q).round()}_${(t.minLat / q).round()}_'
          '$zoomBucket;',
        );
      }
      final newKey = keyBuf.toString();
      if (newKey == _detailKey) return;

      // Render each region (sequential; each is viewport-sized).
      final rendered = <_DetailTarget, PageOverlay>{};
      for (final t in targets) {
        if (gen != _detailGen) return; // cancelled
        try {
          final overlay = await _scope.renderService.renderRegion(
            pdfPath: _scope.library.pdfPath(t.map),
            georef: t.page.georef,
            minLon: t.minLon,
            minLat: t.minLat,
            maxLon: t.maxLon,
            maxLat: t.maxLat,
            targetWidthPx: t.targetWidthPx,
          );
          rendered[t] = overlay;
        } catch (e) {
          debugPrint('Patok: detail render failed: $e');
        }
      }
      if (gen != _detailGen) return; // cancelled while rendering
      if (!mounted) return;

      // Swap in the new detail layers (below annotations, above base).
      await _clearDetailOverlay();
      for (final entry in rendered.entries) {
        final t = entry.key;
        final overlay = entry.value;
        final sid = '$_detailSrcPrefix${t.map.id}_${t.page.pageIndex}';
        final lid = '$_detailLyrPrefix${t.map.id}_${t.page.pageIndex}';
        final quad = LatLngQuad(
          topLeft: LatLng(overlay.corners[0].y, overlay.corners[0].x),
          topRight: LatLng(overlay.corners[1].y, overlay.corners[1].x),
          bottomRight: LatLng(overlay.corners[2].y, overlay.corners[2].x),
          bottomLeft: LatLng(overlay.corners[3].y, overlay.corners[3].x),
        );
        try {
          await c.addImageSource(sid, overlay.pngBytes, quad);
          await c.addRasterLayer(
            sid,
            lid,
            RasterLayerProperties(rasterOpacity: t.map.opacity),
            belowLayerId: _lyrGrid,
          );
          _detailSourceIds.add(sid);
          _detailLayerIds.add(lid);
        } catch (e) {
          debugPrint('Patok: detail layer failed: $e');
        }
      }
      _detailKey = newKey;
    } catch (e) {
      debugPrint('Patok: detail overlay failed: $e');
    }
  }

  /// Guards the native map against out-of-range coordinates.
  ///
  /// When a PDF's coordinate system can't be resolved (e.g. a projected
  /// CRS without usable WKT), the raw projected values would otherwise be
  /// fed to MapLibre as lon/lat (latitude 9,234,500, …) and kill the app
  /// natively. Fail loudly in Dart instead, with a diagnosable message.
  void _validateQuad(List<math.Point<double>> corners, GeoMapPage page) {
    var minLon = double.infinity, maxLon = -double.infinity;
    var minLat = double.infinity, maxLat = -double.infinity;
    for (final p in corners) {
      final lon = p.x, lat = p.y;
      if (!lon.isFinite || !lat.isFinite) {
        throw StateError(
          'Page "${page.name}" has non-finite coordinates. '
          'Coordinate system: ${page.georef.crsDescription ?? 'unknown'}.',
        );
      }
      minLon = math.min(minLon, lon);
      maxLon = math.max(maxLon, lon);
      minLat = math.min(minLat, lat);
      maxLat = math.max(maxLat, lat);
    }
    final crs = page.georef.crsDescription ?? 'unknown';
    if (minLon < -180 || maxLon > 180 || minLat < -90 || maxLat > 90) {
      throw StateError(
        'Page "${page.name}" coordinates are outside the valid world range '
        '(lon ${minLon.toStringAsFixed(1)}…${maxLon.toStringAsFixed(1)}, '
        'lat ${minLat.toStringAsFixed(1)}…${maxLat.toStringAsFixed(1)}). '
        'Its coordinate system ($crs) is not supported yet.',
      );
    }
    if (maxLon - minLon < 1e-9 || maxLat - minLat < 1e-9) {
      throw StateError(
        'Page "${page.name}" has a degenerate (zero-area) map extent.',
      );
    }
  }

  Future<void> _zoomToMap(GeoMap map) async {
    final c = _controller;
    if (c == null || map.pages.isEmpty) return;
    // Fit the first page's corners.
    final corners = map.pages.first.cornerLonLat;
    double minLon = 180, maxLon = -180, minLat = 90, maxLat = -90;
    for (final p in corners) {
      minLon = math.min(minLon, p[0]);
      maxLon = math.max(maxLon, p[0]);
      minLat = math.min(minLat, p[1]);
      maxLat = math.max(maxLat, p[1]);
    }
    await c.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLon),
          northeast: LatLng(maxLat, maxLon),
        ),
        left: 24,
        top: 24,
        right: 24,
        bottom: 24,
      ),
    );
  }

  // -------------------------------------------------------------- layers

  /// Applies a map's visibility/opacity without re-rendering its PDF
  /// pages: the image source is kept, only the raster layer is re-added.
  Future<void> _applyLayerState(GeoMap map) async {
    final c = _controller;
    if (c == null) return;
    for (final page in map.pages) {
      final sid = _sourceId(map, page);
      final lid = _layerId(map, page);
      final hasLayer = _layerIds.contains(lid);
      if (map.visible && !hasLayer) {
        if (!_sourceIds.contains(sid)) {
          // Source is gone (e.g. style reloaded mid-sheet); fall back
          // to a full refresh.
          await _refreshOverlays();
          return;
        }
        await _addPdfRasterLayer(c, sid, lid, map.opacity);
        _layerIds.add(lid);
      } else if (!map.visible && hasLayer) {
        try {
          await c.removeLayer(lid);
        } catch (_) {}
        _layerIds.remove(lid);
        // The detail overlay belongs to this page: hide it too.
        await _removeDetailForPage(map, page);
      } else if (map.visible && hasLayer) {
        // Opacity changed: re-add the layer with the new opacity.
        // The image source is untouched, so no re-render happens.
        try {
          await c.removeLayer(lid);
        } catch (_) {}
        _layerIds.remove(lid);
        await _addPdfRasterLayer(c, sid, lid, map.opacity);
        _layerIds.add(lid);
        // Keep the detail overlay at the same opacity.
        final dlid = '$_detailLyrPrefix${map.id}_${page.pageIndex}';
        if (_detailLayerIds.contains(dlid)) {
          try {
            await c.setLayerProperties(
              dlid,
              RasterLayerProperties(rasterOpacity: map.opacity),
            );
          } catch (_) {}
        }
      }
    }
  }

  // ------------------------------------------------- public tab API

  /// Re-renders overlays for all visible maps (e.g. after an import).
  Future<void> refreshOverlays() => _refreshOverlays();

  /// Opens a map: renders its overlay if needed, then zooms to it.
  Future<void> openMap(GeoMap map) async {
    await _refreshOverlays();
    await _zoomToMap(map);
  }

  /// Called by the home shell when the Map tab becomes visible: refreshes
  /// overlays only if the library (or render DPI) changed while hidden,
  /// and always redraws annotations (field data may have changed).
  Future<void> didBecomeVisible() async {
    if (_libraryFingerprint() != _lastFingerprint ||
        _scope.settings.renderDpi != _lastDpi) {
      await _refreshOverlays();
    }
    _updateCoordReadout();
    await _redrawAnnotations();
    // Settings (e.g. the detail toggle) may have changed while away.
    _maybeUpdateDetailOverlay();
  }

  /// Enters measure mode (idempotent; safe to call when already active).
  void startMeasureMode() {
    if (!_measureMode) _toggleMeasure();
  }

  /// Centers the camera on the current GPS position.
  Future<void> goToGps() => _goToGps();

  int _libraryFingerprint() {
    final maps = _scope.library.maps;
    var h = maps.length * 31 + 7;
    for (final m in maps) {
      h = h * 31 + m.id.hashCode + (m.visible ? 1 : 0);
    }
    return h;
  }

  void _showLayersSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _LayersSheet(
        maps: _scope.library.maps,
        showGrid: _scope.settings.showUtmGrid,
        onStateChanged: (m) async {
          await _scope.library.save();
          if (mounted) setState(() {});
          await _applyLayerState(m);
        },
        onGridChanged: (v) async {
          await _scope.settings.setShowUtmGrid(v);
          if (mounted) setState(() {});
          await _redrawAnnotations();
        },
        onZoom: (m) {
          Navigator.pop(ctx);
          _zoomToMap(m);
        },
      ),
    );
  }

  // ---------------------------------------------------------- annotations
  // Annotation layers are managed directly through the style API — not
  // through the plugin's annotation managers. Two reasons:
  //  1. z-order: PDF raster overlays are added with belowLayerId pointing
  //     at the bottom of this stack, so _refreshOverlays() can never bury
  //     waypoints/measurements again (the old managers' layers were
  //     re-buried on every openMap, and redraws kept them buried).
  //  2. lifecycle: stable layer IDs, re-created after every style load;
  //     no silent "manager not initialized" swallows.
  // Stack, bottom -> top: grid, saved measurements, live track,
  // measure line + points, waypoints.

  static const _srcGrid = 'patok_src_grid';
  static const _lyrGrid = 'patok_lyr_grid';
  static const _srcMeasurements = 'patok_src_measurements';
  static const _lyrMeasurements = 'patok_lyr_measurements';
  static const _srcTrack = 'patok_src_track';
  static const _lyrTrack = 'patok_lyr_track';
  static const _srcMeasure = 'patok_src_measure';
  static const _lyrMeasureFill = 'patok_lyr_measure_fill';
  static const _lyrMeasureLine = 'patok_lyr_measure_line';
  static const _lyrMeasurePts = 'patok_lyr_measure_pts';
  static const _srcWaypoints = 'patok_src_waypoints';
  static const _lyrWaypoints = 'patok_lyr_waypoints';

  bool _annLayersReady = false;

  static Map<String, dynamic> _emptyFc() => {
    'type': 'FeatureCollection',
    'features': [],
  };

  static Map<String, dynamic> _pointsFc(Iterable<List<double>> lonLat) => {
    'type': 'FeatureCollection',
    'features': [
      for (final p in lonLat)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [p[0], p[1]],
          },
          'properties': {},
        },
    ],
  };

  static Map<String, dynamic> _linesFc(
    Iterable<Iterable<List<double>>> lines,
  ) => {
    'type': 'FeatureCollection',
    'features': [
      for (final line in lines)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final p in line) [p[0], p[1]],
            ],
          },
          'properties': {},
        },
    ],
  };

  /// Creates the annotation sources/layers. Idempotent per style load;
  /// must run before any raster overlay is added with belowLayerId.
  Future<void> _ensureAnnotationLayers() async {
    final c = _controller;
    if (c == null || _annLayersReady) return;
    try {
      // Clean up any partial previous run first.
      for (final lid in [
        _lyrGrid,
        _lyrMeasurements,
        _lyrTrack,
        _lyrMeasureFill,
        _lyrMeasureLine,
        _lyrMeasurePts,
        _lyrWaypoints,
      ]) {
        try {
          await c.removeLayer(lid);
        } catch (_) {}
      }
      for (final sid in [
        _srcGrid,
        _srcMeasurements,
        _srcTrack,
        _srcMeasure,
        _srcWaypoints,
      ]) {
        try {
          await c.removeSource(sid);
        } catch (_) {}
      }
      await c.addGeoJsonSource(_srcGrid, _emptyFc());
      await c.addLineLayer(
        _srcGrid,
        _lyrGrid,
        const LineLayerProperties(
          lineColor: '#9AA7B2',
          lineWidth: 1.0,
          lineOpacity: 0.45,
        ),
      );
      await c.addGeoJsonSource(_srcMeasurements, _emptyFc());
      await c.addLineLayer(
        _srcMeasurements,
        _lyrMeasurements,
        const LineLayerProperties(lineColor: '#4CAF50', lineWidth: 3.0),
      );
      await c.addGeoJsonSource(_srcTrack, _emptyFc());
      await c.addLineLayer(
        _srcTrack,
        _lyrTrack,
        const LineLayerProperties(lineColor: '#FF6B1A', lineWidth: 4.0),
      );
      await c.addGeoJsonSource(_srcMeasure, _emptyFc());
      await c.addFillLayer(
        _srcMeasure,
        _lyrMeasureFill,
        const FillLayerProperties(
          fillColor: '#FF6B1A',
          fillOpacity: 0.25,
        ),
      );
      await c.addLineLayer(
        _srcMeasure,
        _lyrMeasureLine,
        const LineLayerProperties(lineColor: '#FF6B1A', lineWidth: 4.0),
      );
      await c.addCircleLayer(
        _srcMeasure,
        _lyrMeasurePts,
        const CircleLayerProperties(
          circleRadius: 7.0,
          circleColor: '#FF6B1A',
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#000000',
        ),
      );
      await c.addGeoJsonSource(_srcWaypoints, _emptyFc());
      await c.addCircleLayer(
        _srcWaypoints,
        _lyrWaypoints,
        const CircleLayerProperties(
          circleRadius: 8.0,
          circleColor: '#2196F3',
          circleStrokeWidth: 2.0,
          circleStrokeColor: '#FFFFFF',
        ),
      );
      _annLayersReady = true;
    } catch (e) {
      debugPrint('Patok: annotation layers failed: $e');
      _annLayersReady = false;
    }
  }

  /// Single clear + redraw for everything above the map: UTM grid (if
  /// enabled) -> saved measurements -> live track -> measure line ->
  /// waypoints. Only rewrites GeoJSON data; layer order never changes.
  Future<void> _redrawAnnotations() async {
    final c = _controller;
    if (c == null || !_annLayersReady) return;
    try {
      // UTM grid.
      if (_scope.settings.showUtmGrid) {
        await c.setGeoJsonSource(_srcGrid, _linesFc(await _gridLineCoords(c)));
      } else {
        await c.setGeoJsonSource(_srcGrid, _emptyFc());
      }

      // Saved measurements (green); area ones draw as closed loops.
      final ms = await _scope.fieldData.measurements();
      await c.setGeoJsonSource(
        _srcMeasurements,
        _linesFc(ms.map(
          (m) => m.areaSqMeters != null && m.points.length >= 3
              ? [...m.points, m.points.first]
              : m.points,
        )),
      );

      // In-progress track recording (orange).
      final liveTrack = _trackRecorder.livePoints.value;
      await c.setGeoJsonSource(
        _srcTrack,
        liveTrack.length >= 2 ? _linesFc([liveTrack]) : _emptyFc(),
      );

      // Active measure line + vertices (+ filled polygon for area).
      if (_measureMode && _measurePoints.isNotEmpty) {
        final pts = _measurePoints
            .map((p) => [p.longitude, p.latitude])
            .toList();
        final ring = pts.length >= 3 ? [...pts, pts.first] : null;
        await c.setGeoJsonSource(_srcMeasure, {
          'type': 'FeatureCollection',
          'features': [
            if (ring != null)
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'Polygon',
                  'coordinates': [ring],
                },
                'properties': {},
              },
            if (pts.length >= 2)
              {
                'type': 'Feature',
                'geometry': {'type': 'LineString', 'coordinates': pts},
                'properties': {},
              },
            for (final p in pts)
              {
                'type': 'Feature',
                'geometry': {'type': 'Point', 'coordinates': p},
                'properties': {},
              },
          ],
        });
      } else {
        await c.setGeoJsonSource(_srcMeasure, _emptyFc());
      }

      // Waypoints (blue pins).
      final wps = await _scope.fieldData.waypoints();
      await c.setGeoJsonSource(
        _srcWaypoints,
        _pointsFc(wps.map((w) => [w.longitude, w.latitude])),
      );
    } catch (e) {
      debugPrint('Patok: _redrawAnnotations failed: $e');
    }
    if (mounted) setState(() {});
  }

  /// UTM grid line coordinates ([lon, lat] pairs) for the visible region.
  /// Line spacing follows the visible width. Returns empty when the region
  /// is unknown.
  Future<List<List<List<double>>>> _gridLineCoords(
    MapLibreMapController c,
  ) async {
    final region = await c.getVisibleRegion();
    final midLat =
        (region.northeast.latitude + region.southwest.latitude) / 2;
    // Visible width in meters (replaces the old zoom-based tiers — the
    // plugin's cached zoom can go stale).
    final widthMeters = Geolocator.distanceBetween(
      midLat,
      region.southwest.longitude,
      midLat,
      region.northeast.longitude,
    );
    final interval = widthMeters < 8000
        ? 500.0
        : widthMeters < 30000
        ? 1000.0
        : widthMeters < 120000
        ? 2000.0
        : widthMeters < 500000
        ? 5000.0
        : 10000.0;
    final centerLon =
        (region.northeast.longitude + region.southwest.longitude) / 2;
    final centerLat =
        (region.northeast.latitude + region.southwest.latitude) / 2;
    final zone = ((centerLon + 180) / 6).floor() + 1;
    final utm = proj4.Projection.parse(
      '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs'
      '${centerLat < 0 ? ' +south' : ''}',
    );
    math.Point<double> toUtm(double lon, double lat) {
      final p = proj4.Projection.WGS84.transform(
        utm,
        proj4.Point(x: lon, y: lat),
      );
      return math.Point(p.x, p.y);
    }

    final sw = toUtm(region.southwest.longitude, region.southwest.latitude);
    final ne = toUtm(region.northeast.longitude, region.northeast.latitude);
    final minE = math.min(sw.x, ne.x), maxE = math.max(sw.x, ne.x);
    final minN = math.min(sw.y, ne.y), maxN = math.max(sw.y, ne.y);

    List<List<double>> gridLine({
      double? easting,
      double? northing,
      double? minE,
      double? maxE,
      double? minN,
      double? maxN,
    }) {
      const samples = 24;
      final pts = <List<double>>[];
      for (var i = 0; i <= samples; i++) {
        double x, y;
        if (easting != null) {
          x = easting;
          y = minN! + (maxN! - minN) * i / samples;
        } else {
          x = minE! + (maxE! - minE) * i / samples;
          y = northing!;
        }
        final p = utm.transform(
          proj4.Projection.WGS84,
          proj4.Point(x: x, y: y),
        );
        pts.add([p.x, p.y]);
      }
      return pts;
    }

    const maxLines = 40;
    final lines = <List<List<double>>>[];
    var e = (minE / interval).floor() * interval;
    var count = 0;
    while (e <= maxE && count < maxLines) {
      lines.add(gridLine(easting: e, minN: minN, maxN: maxN));
      e += interval;
      count++;
    }
    var n = (minN / interval).floor() * interval;
    count = 0;
    while (n <= maxN && count < maxLines) {
      lines.add(gridLine(northing: n, minE: minE, maxE: maxE));
      n += interval;
      count++;
    }
    return lines;
  }

  // -------------------------------------------------------------- measure

  void _toggleMeasure() {
    setState(() {
      _measureMode = !_measureMode;
      _measurePoints.clear();
    });
    _redrawAnnotations();
  }

  Future<void> _onMapClick(math.Point<double> point, LatLng latLng) async {
    if (!_measureMode) return;
    setState(() => _measurePoints.add(latLng));
    await _redrawAnnotations();
  }

  double get _measureLength {
    var total = 0.0;
    for (var i = 1; i < _measurePoints.length; i++) {
      total += Geolocator.distanceBetween(
        _measurePoints[i - 1].latitude,
        _measurePoints[i - 1].longitude,
        _measurePoints[i].latitude,
        _measurePoints[i].longitude,
      );
    }
    return total;
  }

  double get _measureArea {
    if (_measurePoints.length < 3) return 0;
    return polygonAreaSqMeters(
      _measurePoints.map((p) => [p.longitude, p.latitude]).toList(),
    );
  }

  Future<void> _saveMeasurement() async {
    if (_measurePoints.length < 2) return;
    final name = 'Measurement ${_measurePoints.length} pts';
    final ms = await _scope.fieldData.measurements();
    ms.add(
      Measurement(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        points: _measurePoints.map((p) => [p.longitude, p.latitude]).toList(),
        lengthMeters: _measureLength,
        areaSqMeters: _measurePoints.length >= 3 ? _measureArea : null,
      ),
    );
    await _scope.fieldData.saveMeasurements(ms);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Measurement saved')));
    }
    _toggleMeasure();
  }

  // ----------------------------------------------------------------- gps

  Future<void> _goToGps() async {
    var pos = _lastGps ?? await _scope.locationService.currentPosition();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No GPS fix yet')));
      }
      return;
    }
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16),
    );
  }

  // ----------------------------------------------------------- readout

  void _onSatellitesChanged() {
    if (mounted) setState(() {});
  }

  /// Meters per screen pixel derived from the *visible region* (fresh
  /// method-channel data), never from `controller.cameraPosition` — the
  /// plugin's cached position can go stale (non-finite native values are
  /// never cached), which once froze the scale bar at "200 km" and kept
  /// the detail zoom from ever engaging.
  double _metersPerPixel(LatLngBounds region) {
    final midLat =
        (region.northeast.latitude + region.southwest.latitude) / 2;
    final meters = Geolocator.distanceBetween(
      midLat,
      region.southwest.longitude,
      midLat,
      region.northeast.longitude,
    );
    final widthPx = MediaQuery.of(context).size.width *
        MediaQuery.of(context).devicePixelRatio;
    if (meters <= 0 || widthPx <= 0) return 0;
    return meters / widthPx;
  }

  DateTime _lastMppRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _refreshMetersPerPx() async {
    final c = _controller;
    if (c == null || !mounted) return;
    try {
      final region = await c.getVisibleRegion();
      final mpp = _metersPerPixel(region);
      if (mpp > 0) _metersPerPx.value = mpp;
    } catch (_) {}
  }

  void _updateCoordReadout() {
    // Prefer the GPS position like dedicated field apps do; the map
    // center is only a fallback before the first fix. (The plugin's
    // cached cameraPosition can lag behind the actual camera, which
    // once showed a stale default-Jakarta readout.)
    final gps = _lastGps;
    final double lon, lat;
    if (gps != null) {
      lon = gps.longitude;
      lat = gps.latitude;
    } else {
      final target = _controller?.cameraPosition?.target;
      if (target == null) return;
      lon = target.longitude;
      lat = target.latitude;
    }
    final fmt = _scope.settings.coordFormat;
    final text = fmt == 'utm'
        ? formatUtm(lon, lat)
        : '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
    if (mounted && text != _coordText) setState(() => _coordText = text);
  }

  // ----------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_styleJson != null)
            MapLibreMap(
              styleString: _styleJson!,
              myLocationEnabled: true,
              myLocationRenderMode: MyLocationRenderMode.compass,
              myLocationTrackingMode: MyLocationTrackingMode.none,
              initialCameraPosition: const CameraPosition(
                target: LatLng(-6.2, 106.8), // Jakarta; moves on first import
                zoom: 5,
              ),
              onMapCreated: (c) => _controller = c,
              onStyleLoadedCallback: _onStyleLoaded,
              onMapClick: _onMapClick,
              onCameraMove: (_) {
                // Cancel any in-flight detail render: the viewport moved.
                _detailGen++;
                // Throttled scale-bar refresh from the live region.
                final now = DateTime.now();
                if (now.difference(_lastMppRefresh).inMilliseconds > 400) {
                  _lastMppRefresh = now;
                  _refreshMetersPerPx();
                }
              },
              onCameraIdle: () {
                _refreshMetersPerPx();
                _updateCoordReadout();
                _redrawAnnotations();
                _maybeUpdateDetailOverlay();
              },
            )
          else
            const Center(child: CircularProgressIndicator()),
          // Top bar.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: PatokTheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.map, color: PatokTheme.accent, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      _measureMode ? 'Measure: tap the map' : 'Patok',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Empty state (no maps yet) like the mockup.
          if (_scope.library.maps.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: PatokTheme.accent.withValues(alpha: 0.15),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(24),
                          topRight: Radius.circular(24),
                          bottomLeft: Radius.circular(24),
                          bottomRight: Radius.circular(7),
                        ),
                      ),
                      child: const Icon(
                        Icons.map_outlined,
                        color: PatokTheme.accent,
                        size: 36,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'No map open yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Import a georeferenced PDF to start working offline.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: widget.onBrowseMaps,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Browse library'),
                    ),
                  ],
                ),
              ),
            ),
          // Right-side FABs.
          SafeArea(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'gps',
                      onPressed: _goToGps,
                      child: const Icon(Icons.my_location),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton.small(
                      heroTag: 'layers',
                      onPressed: _showLayersSheet,
                      child: const Icon(Icons.layers),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton.small(
                      heroTag: 'measure',
                      backgroundColor: _measureMode ? PatokTheme.accent : null,
                      onPressed: _toggleMeasure,
                      child: const Icon(Icons.straighten),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Bottom: scale bar + measure panel or coordinate readout.
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: _ScaleBar(metersPerPx: _metersPerPx),
                    ),
                    _measureMode
                        ? _MeasurePanel(
                            lengthMeters: _measureLength,
                            areaSqMeters: _measureArea,
                            pointCount: _measurePoints.length,
                            onUndo: () async {
                              if (_measurePoints.isNotEmpty) {
                                setState(() => _measurePoints.removeLast());
                                await _redrawAnnotations();
                              }
                            },
                            onSave: _saveMeasurement,
                            onClose: _toggleMeasure,
                          )
                        : _GpsBar(
                            coordText: _coordText,
                            position: _lastGps,
                            satellites: _gnssService.satellites.value,
                            busy: _busy,
                            status: _status,
                          ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GpsBar extends StatefulWidget {
  const _GpsBar({
    required this.coordText,
    required this.position,
    required this.satellites,
    required this.busy,
    this.status,
  });
  final String coordText;
  final Position? position;
  final (int, int)? satellites;
  final bool busy;
  final String? status;

  @override
  State<_GpsBar> createState() => _GpsBarState();
}

class _GpsBarState extends State<_GpsBar> {
  Timer? _ageTimer;

  @override
  void initState() {
    super.initState();
    // Refresh the "fix age" label while the fix goes stale.
    _ageTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && widget.position != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final pos = widget.position;
    final stats = <String>[];
    if (pos != null) {
      stats.add('ELEV ${pos.altitude.toStringAsFixed(0)}m');
      final vAcc = pos.altitudeAccuracy;
      final vTxt = pos.hasAltitudeAccuracy && vAcc.isFinite
          ? ' V±${vAcc.toStringAsFixed(0)}m'
          : '';
      stats.add('H±${pos.accuracy.toStringAsFixed(0)}m$vTxt');
      final sat = widget.satellites;
      if (sat != null) stats.add('SAT ${sat.$1}/${sat.$2}');
      final kmh = pos.speed * 3.6;
      if (kmh.isFinite && kmh >= 0.5) stats.add('${kmh.toStringAsFixed(0)} km/h');
      final age = DateTime.now().difference(pos.timestamp);
      stats.add(_formatAge(age));
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: PatokTheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.place, color: PatokTheme.accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.status ?? widget.coordText,
                  style: textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['monospace'],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                color: PatokTheme.onSurfaceDim,
                tooltip: 'Copy coordinates',
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.coordText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Coordinates copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              stats.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(
                color: PatokTheme.onSurfaceDim,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['monospace'],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatAge(Duration age) {
    if (age.inSeconds < 10) return 'now';
    if (age.inMinutes < 1) return '${age.inSeconds}s ago';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    return '${age.inHours}h ago';
  }
}

/// Dynamic scale bar: picks a nice round distance for ~90px at the
/// current meters-per-pixel and draws a labeled bar.
class _ScaleBar extends StatelessWidget {
  const _ScaleBar({required this.metersPerPx});
  final ValueNotifier<double> metersPerPx;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: metersPerPx,
      builder: (context, mpp, _) {
        if (!mpp.isFinite || mpp <= 0) return const SizedBox.shrink();
        // Largest nice number (1/2/5 × 10ⁿ) fitting in ~90px.
        final raw = mpp * 90;
        final exp = (math.log(raw) / math.ln10).floor();
        final base = math.pow(10, exp).toDouble();
        var nice = base;
        for (final m in [5, 2, 1]) {
          if (m * base <= raw) {
            nice = m * base;
            break;
          }
        }
        final px = (nice / mpp).clamp(28.0, 220.0);
        final label = nice >= 1000
            ? '${_trimNum(nice / 1000)} km'
            : '${_trimNum(nice)} m';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: PatokTheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['monospace'],
                    ),
              ),
              const SizedBox(height: 2),
              Container(
                width: px,
                height: 4,
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                        color: PatokTheme.onBg, width: 2),
                    right: BorderSide(
                        color: PatokTheme.onBg, width: 2),
                    bottom: BorderSide(
                        color: PatokTheme.onBg, width: 2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _trimNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

class _MeasurePanel extends StatelessWidget {
  const _MeasurePanel({
    required this.lengthMeters,
    required this.areaSqMeters,
    required this.pointCount,
    required this.onUndo,
    required this.onSave,
    required this.onClose,
  });
  final double lengthMeters;
  final double areaSqMeters;
  final int pointCount;
  final VoidCallback onUndo;
  final VoidCallback onSave;
  final VoidCallback onClose;

  String get _formatted {
    if (lengthMeters < 1000) return '${lengthMeters.toStringAsFixed(1)} m';
    return '${(lengthMeters / 1000).toStringAsFixed(2)} km';
  }

  String get _formattedArea {
    if (areaSqMeters < 10000) return '${areaSqMeters.toStringAsFixed(0)} m²';
    return '${(areaSqMeters / 10000).toStringAsFixed(2)} ha';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PatokTheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Distance: $_formatted',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
            ],
          ),
          if (areaSqMeters > 0)
            Text(
              'Area: $_formattedArea',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PatokTheme.accent,
                  ),
            ),
          Text(
            '$pointCount point(s) — tap map to add',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: pointCount > 0 ? onUndo : null,
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: pointCount >= 2 ? onSave : null,
                icon: const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LayersSheet extends StatefulWidget {
  const _LayersSheet({
    required this.maps,
    required this.showGrid,
    required this.onStateChanged,
    required this.onGridChanged,
    required this.onZoom,
  });
  final List<GeoMap> maps;
  final bool showGrid;
  final Future<void> Function(GeoMap) onStateChanged;
  final Future<void> Function(bool) onGridChanged;
  final void Function(GeoMap) onZoom;

  @override
  State<_LayersSheet> createState() => _LayersSheetState();
}

class _LayersSheetState extends State<_LayersSheet> {
  late bool _showGrid;

  @override
  void initState() {
    super.initState();
    _showGrid = widget.showGrid;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Layers', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                title: const Text('UTM grid'),
                subtitle: const Text('Coordinate grid over the map'),
                value: _showGrid,
                onChanged: (v) async {
                  setState(() => _showGrid = v);
                  await widget.onGridChanged(v);
                },
              ),
            ),
            const SizedBox(height: 8),
            if (widget.maps.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No maps yet.\nImport a georeferenced PDF to begin.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.maps.length,
                  itemBuilder: (_, i) {
                    final m = widget.maps[i];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        m.name,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      Text(
                                        '${m.pages.length} page(s) georeferenced',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.center_focus_strong),
                                  tooltip: 'Zoom to map',
                                  onPressed: () => widget.onZoom(m),
                                ),
                                Switch(
                                  value: m.visible,
                                  onChanged: (v) async {
                                    setState(() => m.visible = v);
                                    await widget.onStateChanged(m);
                                  },
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                const Icon(
                                  Icons.opacity,
                                  size: 18,
                                  color: PatokTheme.onSurfaceDim,
                                ),
                                Expanded(
                                  child: Slider(
                                    value: m.opacity,
                                    onChanged: (v) =>
                                        setState(() => m.opacity = v),
                                    onChangeEnd: (_) =>
                                        widget.onStateChanged(m),
                                  ),
                                ),
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    '${(m.opacity * 100).round()}%',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A high-detail re-render request for one visible page region.
class _DetailTarget {
  _DetailTarget({
    required this.map,
    required this.page,
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
    required this.targetWidthPx,
  });

  final GeoMap map;
  final GeoMapPage page;
  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;
  final double targetWidthPx;
}
