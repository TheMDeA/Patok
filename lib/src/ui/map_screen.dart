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

  // Measure mode.
  bool _measureMode = false;
  final List<LatLng> _measurePoints = [];

  // Coordinate readout.
  String _coordText = '—';
  StreamSubscription<Position>? _posSub;
  Position? _lastGps;

  late final TrackRecorder _trackRecorder;

  AppScope get _scope => AppScope.of(context);

  @override
  void initState() {
    super.initState();
    _loadStyle();
    _startGps();
    _trackRecorder = AppScope.of(context).trackRecorder;
    _trackRecorder.livePoints.addListener(_onTrackUpdate);
  }

  void _onTrackUpdate() {
    _redrawAnnotations();
  }

  @override
  void dispose() {
    _trackRecorder.livePoints.removeListener(_onTrackUpdate);
    _posSub?.cancel();
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
    });
  }

  // ------------------------------------------------------------ overlays

  String _sourceId(GeoMap m, GeoMapPage p) => 'fa_src_${m.id}_${p.pageIndex}';
  String _layerId(GeoMap m, GeoMapPage p) => 'fa_lyr_${m.id}_${p.pageIndex}';

  Future<void> _onStyleLoaded() async {
    await _refreshOverlays();
    await _redrawAnnotations();
  }

  Future<void> _refreshOverlays() async {
    final c = _controller;
    if (c == null) return;
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
      MapLibreMapController c, GeoMap map, GeoMapPage page) async {
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
    await c.addRasterLayer(
      sid,
      lid,
      RasterLayerProperties(rasterOpacity: map.opacity),
    );
    _sourceIds.add(sid);
    _layerIds.add(lid);
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
    if (minLon < -180 ||
        maxLon > 180 ||
        minLat < -90 ||
        maxLat > 90) {
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
        await c.addRasterLayer(
          sid,
          lid,
          RasterLayerProperties(rasterOpacity: map.opacity),
        );
        _layerIds.add(lid);
      } else if (!map.visible && hasLayer) {
        try {
          await c.removeLayer(lid);
        } catch (_) {}
        _layerIds.remove(lid);
      } else if (map.visible && hasLayer) {
        // Opacity changed: re-add the layer with the new opacity.
        // The image source is untouched, so no re-render happens.
        try {
          await c.removeLayer(lid);
        } catch (_) {}
        _layerIds.remove(lid);
        await c.addRasterLayer(
          sid,
          lid,
          RasterLayerProperties(rasterOpacity: map.opacity),
        );
        _layerIds.add(lid);
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
  // Single clear + redraw for everything drawn above the map: UTM grid
  // (if enabled) -> saved measurements -> waypoints -> the active
  // measure line. Unified so measure mode never wipes field data and
  // z-order stays correct.

  Future<void> _redrawAnnotations() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.clearLines();
    } catch (_) {}
    try {
      await c.clearCircles();
    } catch (_) {}

    if (_scope.settings.showUtmGrid) {
      await _drawUtmGrid(c);
    }

    try {
      final ms = await _scope.fieldData.measurements();
      if (ms.isNotEmpty) {
        await c.addLines(
          ms
              .map((m) => LineOptions(
                    geometry:
                        m.points.map((p) => LatLng(p[1], p[0])).toList(),
                    lineColor: '#4CAF50',
                    lineWidth: 3.0,
                  ))
              .toList(),
        );
      }
    } catch (_) {}

    try {
      final wps = await _scope.fieldData.waypoints();
      if (wps.isNotEmpty) {
        await c.addCircles(
          wps
              .map((w) => CircleOptions(
                    geometry: LatLng(w.latitude, w.longitude),
                    circleRadius: 8.0,
                    circleColor: '#2196F3',
                    circleStrokeWidth: 2.0,
                    circleStrokeColor: '#FFFFFF',
                  ))
              .toList(),
        );
      }
    } catch (_) {}

    // In-progress track recording.
    final liveTrack = _trackRecorder.livePoints.value;
    if (liveTrack.length >= 2) {
      await c.addLine(
        LineOptions(
          geometry: liveTrack.map((p) => LatLng(p[1], p[0])).toList(),
          lineColor: '#FF6B1A',
          lineWidth: 4.0,
        ),
      );
    }

    if (_measureMode && _measurePoints.isNotEmpty) {
      await c.addLine(
        LineOptions(
          geometry: List.of(_measurePoints),
          lineColor: '#FF6B1A',
          lineWidth: 4.0,
        ),
      );
      await c.addCircles(
        _measurePoints
            .map((p) => CircleOptions(
                  geometry: p,
                  circleRadius: 7.0,
                  circleColor: '#FF6B1A',
                  circleStrokeWidth: 2.0,
                  circleStrokeColor: '#000000',
                ))
            .toList(),
      );
    }
    if (mounted) setState(() {});
  }

  /// Draws a UTM grid over the visible region. Line spacing follows zoom.
  Future<void> _drawUtmGrid(MapLibreMapController c) async {
    try {
      final pos = c.cameraPosition;
      if (pos == null) return;
      final region = await c.getVisibleRegion();
      final zoom = pos.zoom;
      final interval = zoom >= 15
          ? 500.0
          : zoom >= 13
              ? 1000.0
              : zoom >= 11
                  ? 2000.0
                  : zoom >= 9
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
            utm, proj4.Point(x: lon, y: lat));
        return math.Point(p.x, p.y);
      }

      final sw = toUtm(
          region.southwest.longitude, region.southwest.latitude);
      final ne = toUtm(
          region.northeast.longitude, region.northeast.latitude);
      final minE = math.min(sw.x, ne.x), maxE = math.max(sw.x, ne.x);
      final minN = math.min(sw.y, ne.y), maxN = math.max(sw.y, ne.y);

      const maxLines = 40;
      final lines = <LineOptions>[];
      var e = (minE / interval).floor() * interval;
      var count = 0;
      while (e <= maxE && count < maxLines) {
        lines.add(_utmGridLine(utm, easting: e, minN: minN, maxN: maxN));
        e += interval;
        count++;
      }
      var n = (minN / interval).floor() * interval;
      count = 0;
      while (n <= maxN && count < maxLines) {
        lines.add(_utmGridLine(utm, northing: n, minE: minE, maxE: maxE));
        n += interval;
        count++;
      }
      if (lines.isNotEmpty) await c.addLines(lines);
    } catch (_) {}
  }

  LineOptions _utmGridLine(
    proj4.Projection utm, {
    double? easting,
    double? northing,
    double? minE,
    double? maxE,
    double? minN,
    double? maxN,
  }) {
    const samples = 24;
    final pts = <LatLng>[];
    for (var i = 0; i <= samples; i++) {
      double x, y;
      if (easting != null) {
        x = easting;
        y = minN! + (maxN! - minN) * i / samples;
      } else {
        x = minE! + (maxE! - minE) * i / samples;
        y = northing!;
      }
      final p =
          utm.transform(proj4.Projection.WGS84, proj4.Point(x: x, y: y));
      pts.add(LatLng(p.y, p.x));
    }
    return LineOptions(
      geometry: pts,
      lineColor: '#9AA7B2',
      lineWidth: 1.0,
      lineOpacity: 0.45,
    );
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

  Future<void> _saveMeasurement() async {
    if (_measurePoints.length < 2) return;
    final name = 'Measurement ${_measurePoints.length} pts';
    final ms = await _scope.fieldData.measurements();
    ms.add(Measurement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      points: _measurePoints.map((p) => [p.longitude, p.latitude]).toList(),
      lengthMeters: _measureLength,
    ));
    await _scope.fieldData.saveMeasurements(ms);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Measurement saved')),
      );
    }
    _toggleMeasure();
  }

  // ----------------------------------------------------------------- gps

  Future<void> _goToGps() async {
    var pos = _lastGps ?? await _scope.locationService.currentPosition();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No GPS fix yet')),
        );
      }
      return;
    }
    await _controller?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 16),
    );
  }

  // ----------------------------------------------------------- readout

  void _updateCoordReadout() {
    final target = _controller?.cameraPosition?.target;
    if (target == null) return;
    final fmt = _scope.settings.coordFormat;
    final text = fmt == 'utm'
        ? formatUtm(target.longitude, target.latitude)
        : '${target.latitude.toStringAsFixed(5)}, '
            '${target.longitude.toStringAsFixed(5)}';
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
              onCameraIdle: () {
                _updateCoordReadout();
                _redrawAnnotations();
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
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: PatokTheme.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.map,
                        color: PatokTheme.accent, size: 20),
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
                      child: const Icon(Icons.map_outlined,
                          color: PatokTheme.accent, size: 36),
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
                      backgroundColor: _measureMode
                          ? PatokTheme.accent
                          : null,
                      onPressed: _toggleMeasure,
                      child: const Icon(Icons.straighten),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Bottom: measure panel or coordinate readout.
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _measureMode
                    ? _MeasurePanel(
                        lengthMeters: _measureLength,
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
                    : _CoordBar(
                        text: _coordText,
                        busy: _busy,
                        status: _status,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoordBar extends StatelessWidget {
  const _CoordBar({required this.text, required this.busy, this.status});
  final String text;
  final bool busy;
  final String? status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: PatokTheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.place,
                color: PatokTheme.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status ?? text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const ['monospace'],
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeasurePanel extends StatelessWidget {
  const _MeasurePanel({
    required this.lengthMeters,
    required this.pointCount,
    required this.onUndo,
    required this.onSave,
    required this.onClose,
  });
  final double lengthMeters;
  final int pointCount;
  final VoidCallback onUndo;
  final VoidCallback onSave;
  final VoidCallback onClose;

  String get _formatted {
    if (lengthMeters < 1000) return '${lengthMeters.toStringAsFixed(1)} m';
    return '${(lengthMeters / 1000).toStringAsFixed(2)} km';
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
              Text('Distance: $_formatted',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              IconButton(
                  onPressed: onClose, icon: const Icon(Icons.close)),
            ],
          ),
          Text('$pointCount point(s) — tap map to add',
              style: Theme.of(context).textTheme.bodySmall),
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
                                      Text(m.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
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
                                const Icon(Icons.opacity,
                                    size: 18,
                                    color: PatokTheme.onSurfaceDim),
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
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
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
