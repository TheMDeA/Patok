import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'app_scope.dart';
import '../models.dart';
import '../geopdf/georef.dart';
import '../theme.dart';
import 'import_screen.dart';
import 'library_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';

/// Map workspace: full-bleed MapLibre map with imported georeferenced
/// PDF pages as image overlays, GPS, layers sheet, measure mode and a
/// coordinate readout bar.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  MapLibreMapController? _controller;
  String? _styleJson;
  bool _busy = false;
  String? _status;

  final Set<String> _sourceIds = {};
  final Set<String> _layerIds = {};

  // Measure mode.
  bool _measureMode = false;
  final List<LatLng> _measurePoints = [];

  // Coordinate readout.
  String _coordText = '—';
  StreamSubscription<Position>? _posSub;
  Position? _lastGps;

  AppScope get _scope => AppScope.of(context);

  @override
  void initState() {
    super.initState();
    _loadStyle();
    _startGps();
  }

  @override
  void dispose() {
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
    for (final map in _scope.library.maps) {
      if (!map.visible) continue;
      for (final page in map.pages) {
        try {
          await _addOverlay(c, map, page);
        } catch (_) {
          failures++;
        }
      }
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status = failures > 0 ? '$failures page(s) failed to render' : null;
      });
    }
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

  void _showLayersSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _LayersSheet(
        maps: _scope.library.maps,
        onChanged: () async {
          await _scope.library.save();
          if (mounted) setState(() {});
          await _refreshOverlays();
        },
        onZoom: (m) {
          Navigator.pop(ctx);
          _zoomToMap(m);
        },
      ),
    );
  }

  // -------------------------------------------------------------- measure

  void _toggleMeasure() {
    setState(() {
      _measureMode = !_measureMode;
      _measurePoints.clear();
    });
    _controller?.clearLines();
    _controller?.clearCircles();
  }

  Future<void> _onMapClick(math.Point<double> point, LatLng latLng) async {
    if (!_measureMode) return;
    setState(() => _measurePoints.add(latLng));
    await _redrawMeasure();
  }

  Future<void> _redrawMeasure() async {
    final c = _controller;
    if (c == null) return;
    await c.clearLines();
    await c.clearCircles();
    if (_measurePoints.isEmpty) return;
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
    setState(() {});
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
              myLocationTrackingMode: MyLocationTrackingMode.none,
              initialCameraPosition: const CameraPosition(
                target: LatLng(-6.2, 106.8), // Jakarta; moves on first import
                zoom: 5,
              ),
              onMapCreated: (c) => _controller = c,
              onStyleLoadedCallback: _onStyleLoaded,
              onMapClick: _onMapClick,
              onCameraIdle: _updateCoordReadout,
            )
          else
            const Center(child: CircularProgressIndicator()),
          // Top bar.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
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
                            _measureMode
                                ? 'Measure: tap the map'
                                : 'Patok',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _MenuButton(
                    onSelected: (v) async {
                      switch (v) {
                        case 'library':
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const LibraryScreen()),
                          );
                          await _refreshOverlays();
                          if (mounted) setState(() {});
                          break;
                        case 'import':
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ImportScreen()),
                          );
                          await _refreshOverlays();
                          if (mounted) setState(() {});
                          break;
                        case 'tools':
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ToolsScreen()),
                          );
                          break;
                        case 'settings':
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const SettingsScreen()),
                          );
                          if (mounted) setState(() {});
                          break;
                      }
                    },
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
                            await _redrawMeasure();
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

class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.onSelected});
  final void Function(String) onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PatokTheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
      ),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, color: PatokTheme.onBg),
        onSelected: onSelected,
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'library',
              child: ListTile(
                  leading: Icon(Icons.folder_open),
                  title: Text('Map library'))),
          PopupMenuItem(
              value: 'import',
              child: ListTile(
                  leading: Icon(Icons.file_download),
                  title: Text('Import map'))),
          PopupMenuItem(
              value: 'tools',
              child: ListTile(
                  leading: Icon(Icons.build), title: Text('Field tools'))),
          PopupMenuItem(
              value: 'settings',
              child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('Settings'))),
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
    required this.onChanged,
    required this.onZoom,
  });
  final List<GeoMap> maps;
  final Future<void> Function() onChanged;
  final void Function(GeoMap) onZoom;

  @override
  State<_LayersSheet> createState() => _LayersSheetState();
}

class _LayersSheetState extends State<_LayersSheet> {
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
                                    await widget.onChanged();
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
                                    onChangeEnd: (_) => widget.onChanged(),
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
