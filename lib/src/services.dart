import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
          (m) => !File('${dir.path}/${m.relativePdfPath}').existsSync());
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
  /// Large pages are capped so the bitmap stays under ~4096px on its long
  /// edge (GL texture limit); v2 will tile instead.
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
      const maxEdge = 4096;
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
        // pdfrx gives BGRA8888; encode as PNG for the map SDK.
        final decoded = img.Image.fromBytes(
          width: image.width,
          height: image.height,
          bytes: image.pixels.buffer,
          numChannels: 4,
          order: img.ChannelOrder.bgra,
        );
        final png = Uint8List.fromList(img.encodePng(decoded));
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
      void Function(String message) onProgress) async {
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
          'georegistration (/VP /Measure) and TerraGo (/LGIDict) maps.');
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
      pages.add(GeoMapPage(
        pageIndex: g.pageIndex,
        name: georefs.length == 1 ? 'Map' : 'Page ${g.pageIndex + 1}',
        georef: g,
        cornerLonLat: corners.map((p) => [p.x, p.y]).toList(),
      ));
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
}

/// App settings backed by SharedPreferences.
class SettingsService {
  SettingsService._(this._prefs);
  final SharedPreferences _prefs;

  static Future<SettingsService> load() async =>
      SettingsService._(await SharedPreferences.getInstance());

  bool get sunlightMode => _prefs.getBool('sunlightMode') ?? false;
  Future<void> setSunlightMode(bool v) =>
      _prefs.setBool('sunlightMode', v);

  /// Render DPI for map overlays (96 / 150 / 300).
  double get renderDpi => _prefs.getDouble('renderDpi') ?? 150;
  Future<void> setRenderDpi(double v) => _prefs.setDouble('renderDpi', v);

  /// 'utm' or 'latlon'.
  String get coordFormat => _prefs.getString('coordFormat') ?? 'utm';
  Future<void> setCoordFormat(String v) =>
      _prefs.setString('coordFormat', v);

  bool get showUtmGrid => _prefs.getBool('showUtmGrid') ?? false;
  Future<void> setShowUtmGrid(bool v) => _prefs.setBool('showUtmGrid', v);
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
