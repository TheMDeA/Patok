import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'geopdf/georef.dart';
import 'geopdf/pdf_parser.dart';
import 'models.dart';

const _uuid = Uuid();

/// Arguments for [_encodePngIsolate]; must be a simple transferable type.
class _PngEncodeArgs {
  _PngEncodeArgs(this.width, this.height, this.bgra);
  final int width;
  final int height;
  final Uint8List bgra;
}

/// Encodes BGRA8888 pixels as PNG. Runs on a background isolate via
/// [compute] so large pages don't freeze or OOM the UI thread.
Uint8List _encodePngIsolate(_PngEncodeArgs args) {
  final decoded = img.Image.fromBytes(
    width: args.width,
    height: args.height,
    bytes: args.bgra.buffer,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  return Uint8List.fromList(img.encodePng(decoded));
}

Future<Directory> _appDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/patok');
  if (!await dir.exists()) await dir.create(recursive: true);
  final maps = Directory('${dir.path}/maps');
  if (!await maps.exists()) await maps.create();
  return dir;
}

/// Persistent library of imported maps (JSON index + copied PDFs).
class MapLibrary {
  MapLibrary._(this._dir, this.maps);
  final Directory _dir;
  final List<GeoMap> maps;

  static Future<MapLibrary> load() async {
    final dir = await _appDir();
    final file = File('${dir.path}/library.json');
    if (!await file.exists()) return MapLibrary._(dir, []);
    try {
      final maps = GeoMap.decodeList(await file.readAsString());
      // Drop entries whose PDF is missing.
      maps.removeWhere(
        (m) => !File('${dir.path}/${m.relativePdfPath}').existsSync(),
      );
      return MapLibrary._(dir, maps);
    } catch (_) {
      return MapLibrary._(dir, []);
    }
  }

  String pdfPath(GeoMap map) => '${_dir.path}/${map.relativePdfPath}';

  Future<void> save() async {
    final file = File('${_dir.path}/library.json');
    await file.writeAsString(GeoMap.encodeList(maps));
  }

  Future<void> add(GeoMap map) async {
    maps.add(map);
    await save();
  }

  Future<void> remove(GeoMap map) async {
    maps.removeWhere((m) => m.id == map.id);
    final pdf = File(pdfPath(map));
    if (await pdf.exists()) await pdf.delete();
    await save();
  }
}

/// Result of rendering one PDF page to a PNG overlay.
class PageOverlay {
  PageOverlay({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.corners,
  });

  final Uint8List pngBytes;
  final int width;
  final int height;

  /// [topLeft, topRight, bottomRight, bottomLeft] as (lon, lat).
  final List<math.Point<double>> corners;
}

/// Renders PDF pages to PNG overlays positioned in WGS84.
class RenderService {
  /// Renders [pageIndex] of the PDF at [pdfPath] at [dpi], returning the
  /// PNG bytes plus the WGS84 corner coordinates for a map image source.
  ///
  /// Large pages are capped so the bitmap stays under ~2048px on its long
  /// edge (memory safety on real devices); v2 will tile instead.
  Future<PageOverlay> renderPage({
    required String pdfPath,
    required PageGeoref georef,
    double dpi = 150,
  }) async {
    final doc = await PdfDocument.openFile(pdfPath);
    try {
      final page = doc.pages[georef.pageIndex];
      var wPx = (georef.pageWidthPt * dpi / 72).round();
      var hPx = (georef.pageHeightPt * dpi / 72).round();
      // Account for /Rotate: PDFium renders rotated.
      final rotated = georef.rotation == 90 || georef.rotation == 270;
      if (rotated) {
        final t = wPx;
        wPx = hPx;
        hPx = t;
      }
      const maxEdge = 2048;
      // Cap well below the GL texture limit: a 2048px RGBA image is ~17MB,
      // while 4096px (67MB) plus PNG-encode working buffers reliably
      // OOM-kills the app on real devices. Tiling (v2) removes the cap.
      final longEdge = math.max(wPx, hPx);
      if (longEdge > maxEdge) {
        final scale = maxEdge / longEdge;
        wPx = (wPx * scale).round();
        hPx = (hPx * scale).round();
      }
      final image = await page.render(
        fullWidth: wPx.toDouble(),
        fullHeight: hPx.toDouble(),
        backgroundColor: 0x00000000,
      );
      if (image == null) {
        throw StateError('Failed to render page ${georef.pageIndex}');
      }
      try {
        // BGRA -> PNG on a background isolate: the pure-Dart encoder
        // blocks the UI thread for seconds on large images (ANR).
        final png = await compute(
          _encodePngIsolate,
          _PngEncodeArgs(image.width, image.height, image.pixels),
        );
        final corners = _corners(
          georef: georef,
          imgW: image.width.toDouble(),
          imgH: image.height.toDouble(),
        );
        return PageOverlay(
          pngBytes: png,
          width: image.width,
          height: image.height,
          corners: corners,
        );
      } finally {
        image.dispose();
      }
    } finally {
      await doc.dispose();
    }
  }

  /// Renders a lon/lat sub-region of a page at high resolution, for the
  /// zoomed-in detail overlay (like native PDF viewers: vector content
  /// re-rasterized at screen sharpness). Only the visible region is
  /// rasterized — never the whole page — so memory stays bounded.
  ///
  /// [targetWidthPx] is the desired width of the *region* in pixels;
  /// the region is capped at 2048px on its long edge for memory safety.
  Future<PageOverlay> renderRegion({
    required String pdfPath,
    required PageGeoref georef,
    required double minLon,
    required double minLat,
    required double maxLon,
    required double maxLat,
    required double targetWidthPx,
  }) async {
    final doc = await PdfDocument.openFile(pdfPath);
    try {
      final page = doc.pages[georef.pageIndex];
      // 1. lon/lat bbox -> PDF user space (points), via inverse projection
      //    and inverse affine. Take the bbox of the 4 corners.
      var ux0 = double.infinity,
          uy0 = double.infinity,
          ux1 = -double.infinity,
          uy1 = -double.infinity;
      for (final c in [
        [minLon, minLat],
        [maxLon, minLat],
        [maxLon, maxLat],
        [minLon, maxLat],
      ]) {
        final s = georef.srcIsLonLat
            ? math.Point(c[0], c[1])
            : toProjected(c[0], c[1], georef.srcWkt);
        final u = inverseAffine(georef, s.x, s.y);
        ux0 = math.min(ux0, u.x);
        uy0 = math.min(uy0, u.y);
        ux1 = math.max(ux1, u.x);
        uy1 = math.max(uy1, u.y);
      }
      // Clamp to the page with a small margin.
      const pad = 8.0;
      ux0 = (ux0 - pad).clamp(0.0, georef.pageWidthPt);
      uy0 = (uy0 - pad).clamp(0.0, georef.pageHeightPt);
      ux1 = (ux1 + pad).clamp(0.0, georef.pageWidthPt);
      uy1 = (uy1 + pad).clamp(0.0, georef.pageHeightPt);
      if (ux1 - ux0 < 1 || uy1 - uy0 < 1) {
        throw StateError('Detail region is empty');
      }

      // 2. Render scale: region width -> targetWidthPx, with the region
      //    capped at 2048px on its long edge (memory safety).
      //    Work in rotated bitmap space (PDFium applies /Rotate).
      final rotated = georef.rotation == 90 || georef.rotation == 270;
      final rotWpt = rotated ? georef.pageHeightPt : georef.pageWidthPt;
      final rotHpt = rotated ? georef.pageWidthPt : georef.pageHeightPt;
      // Region size in rotated points.
      final rpts = [
        for (final u in [
          [ux0, uy0],
          [ux1, uy0],
          [ux1, uy1],
          [ux0, uy1],
        ])
          userToRotatedPoint(
            u[0],
            u[1],
            pageW: georef.pageWidthPt,
            pageH: georef.pageHeightPt,
            rotation: georef.rotation,
          ),
      ];
      final rxs = rpts.map((p) => p.x);
      final rys = rpts.map((p) => p.y);
      final rwPt = rxs.reduce(math.max) - rxs.reduce(math.min);
      final rhPt = rys.reduce(math.max) - rys.reduce(math.min);
      var scale = targetWidthPx / rwPt;
      final regionLongEdge = math.max(rwPt, rhPt) * scale;
      const maxRegionEdge = 2048.0;
      if (regionLongEdge > maxRegionEdge) {
        scale *= maxRegionEdge / regionLongEdge;
      }
      // Cap the virtual full size: beyond this we're past useful sharpness
      // and PDFium's matrix math gets unhappy.
      const maxVirtualEdge = 32768.0;
      final virtualLongEdge = math.max(rotWpt, rotHpt) * scale;
      if (virtualLongEdge > maxVirtualEdge) {
        scale *= maxVirtualEdge / virtualLongEdge;
      }
      final fullW = (rotWpt * scale).round();
      final fullH = (rotHpt * scale).round();

      // 3. Sub-rectangle in virtual pixels.
      final p0 = userToRotatedPx(
        ux0,
        uy0,
        scale: scale,
        pageW: georef.pageWidthPt,
        pageH: georef.pageHeightPt,
        rotation: georef.rotation,
        fullH: fullH.toDouble(),
      );
      final p1 = userToRotatedPx(
        ux1,
        uy1,
        scale: scale,
        pageW: georef.pageWidthPt,
        pageH: georef.pageHeightPt,
        rotation: georef.rotation,
        fullH: fullH.toDouble(),
      );
      var x = math.min(p0.x, p1.x).round().clamp(0, fullW);
      var y = math.min(p0.y, p1.y).round().clamp(0, fullH);
      var w = (math.max(p0.x, p1.x) - math.min(p0.x, p1.x)).round().clamp(
        1,
        fullW - x,
      );
      var h = (math.max(p0.y, p1.y) - math.min(p0.y, p1.y)).round().clamp(
        1,
        fullH - y,
      );

      final image = await page.render(
        x: x,
        y: y,
        width: w,
        height: h,
        fullWidth: fullW.toDouble(),
        fullHeight: fullH.toDouble(),
        backgroundColor: 0x00000000,
      );
      if (image == null) {
        throw StateError('Failed to render region of page ${georef.pageIndex}');
      }
      try {
        final png = await compute(
          _encodePngIsolate,
          _PngEncodeArgs(image.width, image.height, image.pixels),
        );
        final corners = _cornersForRect(
          georef: georef,
          x: x.toDouble(),
          y: y.toDouble(),
          w: w.toDouble(),
          h: h.toDouble(),
          fullW: fullW.toDouble(),
          fullH: fullH.toDouble(),
        );
        return PageOverlay(
          pngBytes: png,
          width: image.width,
          height: image.height,
          corners: corners,
        );
      } finally {
        image.dispose();
      }
    } finally {
      await doc.dispose();
    }
  }

  /// Bitmap corners (TL, TR, BR, BL) in WGS84 lon/lat for an arbitrary
  /// sub-rectangle of a rendered page: maps the rect's pixel corners back
  /// through user space and the page affine into lon/lat.
  List<math.Point<double>> _cornersForRect({
    required PageGeoref georef,
    required double x,
    required double y,
    required double w,
    required double h,
    required double fullW,
    required double fullH,
  }) {
    final px = [
      math.Point(x, y),
      math.Point(x + w, y),
      math.Point(x + w, y + h),
      math.Point(x, y + h),
    ];
    return [
      for (final p in px)
        () {
          final u = pixelToUserSpace(
            px: p.x,
            py: p.y,
            imgW: fullW,
            imgH: fullH,
            pageW: georef.pageWidthPt,
            pageH: georef.pageHeightPt,
            rotation: georef.rotation,
          );
          final sx = georef.a * u.x + georef.b * u.y + georef.c;
          final sy = georef.d * u.x + georef.e * u.y + georef.f;
          if (georef.srcIsLonLat) return math.Point(sx, sy);
          return toLonLat(sx, sy, georef.srcWkt);
        }(),
    ];
  }

  /// Bitmap corners (TL, TR, BR, BL) in WGS84 lon/lat.
  List<math.Point<double>> _corners({
    required PageGeoref georef,
    required double imgW,
    required double imgH,
  }) {
    final px = [
      math.Point(0.0, 0.0),
      math.Point(imgW, 0.0),
      math.Point(imgW, imgH),
      math.Point(0.0, imgH),
    ];
    return [
      for (final p in px)
        () {
          final u = pixelToUserSpace(
            px: p.x,
            py: p.y,
            imgW: imgW,
            imgH: imgH,
            pageW: georef.pageWidthPt,
            pageH: georef.pageHeightPt,
            rotation: georef.rotation,
          );
          final sx = georef.a * u.x + georef.b * u.y + georef.c;
          final sy = georef.d * u.x + georef.e * u.y + georef.f;
          if (georef.srcIsLonLat) return math.Point(sx, sy);
          return toLonLat(sx, sy, georef.srcWkt);
        }(),
    ];
  }
}

/// Import pipeline: pick PDF -> copy into app storage -> parse
/// georeferencing -> register in the library.
class ImportService {
  ImportService(this._library, this._render);
  final MapLibrary _library;
  final RenderService _render;

  /// Lets the user pick a PDF and imports it, reporting progress
  /// messages via [onProgress]. Returns the imported map, or null if
  /// the user cancelled.
  Future<GeoMap?> importWithPicker(
    void Function(String message) onProgress,
  ) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (files.isEmpty) return null;
    final path = files.single.path;
    if (path == null) throw StateError('Picked file has no path');
    return importFile(path, onProgress);
  }

  Future<GeoMap> importFile(
    String sourcePath,
    void Function(String message) onProgress,
  ) async {
    final dir = await _appDir();
    final id = _uuid.v4();
    final fileName = sourcePath.split(Platform.pathSeparator).last;
    final dest = File('${dir.path}/maps/$id.pdf');

    onProgress('Copying file…');
    await File(sourcePath).copy(dest.path);

    onProgress('Reading PDF structure…');
    final bytes = await dest.readAsBytes();
    final parser = PdfParser.parse(bytes);

    onProgress('Extracting georeferencing…');
    final georefs = GeorefExtractor(parser).extractAll();
    if (georefs.isEmpty) {
      await dest.delete();
      throw StateError(
        'No georeferencing found in this PDF. Patok reads OGC '
        'georegistration (/VP /Measure) and TerraGo (/LGIDict) maps.',
      );
    }

    onProgress('Computing map extents…');
    final pages = <GeoMapPage>[];
    for (var i = 0; i < georefs.length; i++) {
      final g = georefs[i];
      // Render a tiny thumbnail-free corner computation: reuse the
      // corner math with a 72dpi-equivalent pixel grid.
      final corners = _render._corners(
        georef: g,
        imgW: g.pageWidthPt,
        imgH: g.pageHeightPt,
      );
      pages.add(
        GeoMapPage(
          pageIndex: g.pageIndex,
          name: georefs.length == 1 ? 'Map' : 'Page ${g.pageIndex + 1}',
          georef: g,
          cornerLonLat: corners.map((p) => [p.x, p.y]).toList(),
        ),
      );
    }

    final map = GeoMap(
      id: id,
      name: fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
      fileName: fileName,
      pages: pages,
    );
    onProgress('Saving to library…');
    await _library.add(map);
    return map;
  }
}

/// GPS location via geolocator (works fully offline; network only
/// speeds up the first fix).
class LocationService {
  Stream<Position>? _stream;
  Stream<Position>? _rawStream;

  Future<bool> ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  Future<Position?> currentPosition() async {
    if (!await ensurePermission()) return null;
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      return await Geolocator.getLastKnownPosition();
    }
  }

  Stream<Position> positionStream() {
    _stream ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 2,
      ),
    );
    return _stream!;
  }

  /// Time-based stream (no distance filter) for stationary work like
  /// waypoint averaging — the main stream goes quiet when not moving.
  Stream<Position> rawPositionStream() {
    _rawStream ??= Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      ),
    );
    return _rawStream!;
  }
}

/// Records a GPS track: explicit start/stop, positions collected from the
/// shared position stream. The live points are exposed so the map can draw
/// the in-progress track; [stop] returns a [Measurement] to save.
class TrackRecorder {
  TrackRecorder(this._locationService);
  final LocationService _locationService;

  final ValueNotifier<bool> isRecording = ValueNotifier(false);
  final ValueNotifier<int> pointCount = ValueNotifier(0);

  /// Live (lon, lat) points while recording; empty when idle.
  final ValueNotifier<List<List<double>>> livePoints = ValueNotifier(const []);

  StreamSubscription<Position>? _sub;
  final List<List<double>> _points = [];

  Future<void> start() async {
    if (isRecording.value) return;
    if (!await _locationService.ensurePermission()) {
      throw StateError('Location permission denied');
    }
    _points.clear();
    pointCount.value = 0;
    livePoints.value = const [];
    _sub = _locationService.positionStream().listen((p) {
      _points.add([p.longitude, p.latitude]);
      pointCount.value = _points.length;
      livePoints.value = List.unmodifiable(_points);
    });
    isRecording.value = true;
  }

  /// Stops recording and returns the track as a [Measurement], or null
  /// when too few points were collected.
  Future<Measurement?> stop(String name) async {
    await _sub?.cancel();
    _sub = null;
    isRecording.value = false;
    final points = List<List<double>>.of(_points);
    _points.clear();
    pointCount.value = 0;
    livePoints.value = const [];
    if (points.length < 2) return null;
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += Geolocator.distanceBetween(
        points[i - 1][1],
        points[i - 1][0],
        points[i][1],
        points[i][0],
      );
    }
    return Measurement(
      id: _uuid.v4(),
      name: name,
      points: points,
      lengthMeters: total,
    );
  }

  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    isRecording.value = false;
    _points.clear();
    pointCount.value = 0;
    livePoints.value = const [];
  }
}

/// App settings backed by SharedPreferences.
class SettingsService {
  SettingsService._(this._prefs) {
    _sunlightMode.value = _prefs.getBool('sunlightMode') ?? false;
  }
  final SharedPreferences _prefs;

  /// Notified whenever sunlight mode changes so the theme applies live.
  final ValueNotifier<bool> _sunlightMode = ValueNotifier(false);
  ValueListenable<bool> get sunlightModeListenable => _sunlightMode;

  static Future<SettingsService> load() async =>
      SettingsService._(await SharedPreferences.getInstance());

  bool get sunlightMode => _sunlightMode.value;
  Future<void> setSunlightMode(bool v) async {
    await _prefs.setBool('sunlightMode', v);
    _sunlightMode.value = v;
  }

  /// Render DPI for map overlays (96 / 150 / 300).
  double get renderDpi => _prefs.getDouble('renderDpi') ?? 150;
  Future<void> setRenderDpi(double v) => _prefs.setDouble('renderDpi', v);

  /// 'utm' or 'latlon'.
  String get coordFormat => _prefs.getString('coordFormat') ?? 'utm';
  Future<void> setCoordFormat(String v) => _prefs.setString('coordFormat', v);

  bool get showUtmGrid => _prefs.getBool('showUtmGrid') ?? false;
  Future<void> setShowUtmGrid(bool v) => _prefs.setBool('showUtmGrid', v);

  /// High-detail re-render of the visible map region when zoomed in
  /// (keeps PDF text sharp like a native viewer). Default on.
  bool get detailZoom => _prefs.getBool('detailZoom') ?? true;
  Future<void> setDetailZoom(bool v) => _prefs.setBool('detailZoom', v);
}

/// GNSS satellite status streamed from the Android side.
/// [satellites] holds (usedInFix, totalInView) or null when unknown.
class GnssService {
  static const _channel = EventChannel('patok/gnss');

  final ValueNotifier<(int, int)?> satellites = ValueNotifier(null);
  StreamSubscription? _sub;

  void start() {
    if (_sub != null) return;
    _sub = _channel.receiveBroadcastStream().listen((event) {
      try {
        final m = Map<String, dynamic>.from(event as Map);
        satellites.value =
            ((m['used'] as num).toInt(), (m['total'] as num).toInt());
      } catch (_) {}
    }, onError: (_) {});
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}

/// Simple JSON store for waypoints and measurements.
class FieldDataStore {
  FieldDataStore._(this._dir);
  final Directory _dir;

  static Future<FieldDataStore> load() async =>
      FieldDataStore._(await _appDir());

  Future<List<Waypoint>> waypoints() async {
    final f = File('${_dir.path}/waypoints.json');
    if (!await f.exists()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List)
          .map((j) => Waypoint.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWaypoints(List<Waypoint> wps) async {
    final f = File('${_dir.path}/waypoints.json');
    await f.writeAsString(jsonEncode(wps.map((w) => w.toJson()).toList()));
  }

  Future<List<Measurement>> measurements() async {
    final f = File('${_dir.path}/measurements.json');
    if (!await f.exists()) return [];
    try {
      return (jsonDecode(await f.readAsString()) as List)
          .map((j) => Measurement.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMeasurements(List<Measurement> ms) async {
    final f = File('${_dir.path}/measurements.json');
    await f.writeAsString(jsonEncode(ms.map((m) => m.toJson()).toList()));
  }
}
