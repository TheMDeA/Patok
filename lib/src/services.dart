import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

import 'dxf/dxf_crs.dart';
import 'dxf/dxf_import.dart';
import 'dxf/dxf_model.dart';
import 'geopdf/georef.dart';
import 'geopdf/pdf_parser.dart';
import 'models.dart';

const _uuid = Uuid();

/// Encodes BGRA8888 pixels as PNG on a background isolate so large
/// pages don't freeze or OOM the UI thread. The pixel buffer is
/// transferred (not copied) via [TransferableTypedData], and the
/// encoder output is returned directly — the old path copied the bitmap
/// ~3x (pixels -> isolate message -> Image.fromBytes -> fromList).
Future<Uint8List> _encodePng(int width, int height, Uint8List bgra) {
  final transferable = TransferableTypedData.fromList([bgra]);
  return Isolate.run(() {
    final bytes = transferable.materialize().asUint8List();
    final decoded = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    return img.encodePng(decoded);
  });
}

/// Cached app-directory future: the platform-channel call + directory
/// stats used to run on every use. Failures are not cached, so a
/// transient error doesn't poison later calls.
Future<Directory>? _appDirCache;

Future<Directory> _appDir() {
  final cached = _appDirCache;
  if (cached != null) return cached;
  final created = _createAppDir();
  _appDirCache = created;
  created.then(
    (_) {},
    onError: (_) {
      if (identical(_appDirCache, created)) _appDirCache = null;
    },
  );
  return created;
}

Future<Directory> _createAppDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/patok');
  if (!await dir.exists()) await dir.create(recursive: true);
  final maps = Directory('${dir.path}/maps');
  if (!await maps.exists()) await maps.create();
  return dir;
}

/// Writes [content] to [file] atomically: write a temp file in the same
/// directory, flush it, then rename over the target. A crash mid-write
/// can leave a stale temp file but never a truncated target.
Future<void> _writeFileAtomic(File file, String content) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  await tmp.rename(file.path);
}

/// Serializes async writes so overlapping saves can't lose updates:
/// each save runs after the previous one completes, and encodes the
/// state at execution time (so the last queued write always holds the
/// latest state). A failing save doesn't break the chain.
class _SaveQueue {
  Future<void> _tail = Future.value();

  Future<void> run(Future<void> Function() task) {
    final run = _tail.then((_) => task());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }
}

/// Persistent library of imported maps (JSON index + copied PDFs)
/// and imported DXF drawings (JSON index + transformed geometry cache).
class MapLibrary {
  MapLibrary._(this._dir, this.maps, this.dxfImports);
  final Directory _dir;
  final List<GeoMap> maps;
  final List<DxfImport> dxfImports;

  static Future<MapLibrary> load() async {
    final dir = await _appDir();
    final file = File('${dir.path}/library.json');
    if (!await file.exists()) return MapLibrary._(dir, [], []);
    try {
      final raw = jsonDecode(await file.readAsString());
      // New format is {"maps": [...], "dxfImports": [...]}; the original
      // format was a bare array of maps.
      final mapsJson = raw is List ? raw : (raw['maps'] as List? ?? []);
      final dxfJson =
          raw is Map ? (raw['dxfImports'] as List? ?? []) : const [];
      // Per-entry tolerance: one corrupt entry is skipped, the rest
      // survive. The old all-or-nothing parse returned an empty library
      // for a single bad entry, and the next save made that permanent.
      final maps = <GeoMap>[];
      for (final j in mapsJson) {
        try {
          maps.add(GeoMap.fromJson(j as Map<String, dynamic>));
        } catch (_) {}
      }
      // Drop entries whose PDF is missing.
      maps.removeWhere(
        (m) => !File('${dir.path}/${m.relativePdfPath}').existsSync(),
      );
      final dxfs = <DxfImport>[];
      for (final j in dxfJson) {
        try {
          dxfs.add(DxfImport.fromJson(j as Map<String, dynamic>));
        } catch (_) {}
      }
      // Drop entries whose geometry cache is missing.
      dxfs.removeWhere(
        (d) => !File('${dir.path}/${d.relativeCachePath}').existsSync(),
      );
      return MapLibrary._(dir, maps, dxfs);
    } catch (_) {
      return MapLibrary._(dir, [], []);
    }
  }

  String pdfPath(GeoMap map) => '${_dir.path}/${map.relativePdfPath}';
  String dxfPath(DxfImport d) => '${_dir.path}/${d.relativeDxfPath}';
  String dxfCachePath(DxfImport d) => '${_dir.path}/${d.relativeCachePath}';

  /// Named mine local grids, stored alongside the library.
  Future<DxfLocalGridStore> dxfLocalGrids() =>
      DxfLocalGridStore.load(_dir);

  final _saveQueue = _SaveQueue();

  Future<void> save() => _saveQueue.run(_writeSave);

  Future<void> _writeSave() async {
    final file = File('${_dir.path}/library.json');
    await _writeFileAtomic(
      file,
      jsonEncode({
        'maps': maps.map((m) => m.toJson()).toList(),
        'dxfImports': dxfImports.map((d) => d.toJson()).toList(),
      }),
    );
  }

  Future<void> add(GeoMap map) async {
    maps.add(map);
    try {
      await save();
    } catch (_) {
      maps.remove(map);
      rethrow;
    }
  }

  /// Removes the entry and deletes its PDF — but only after the library
  /// file has been saved without it. Deleting first would lose the only
  /// copy if the save then failed (e.g. a failed delete-undo rename).
  Future<void> remove(GeoMap map) async {
    final index = maps.indexWhere((m) => m.id == map.id);
    if (index < 0) return;
    final removed = maps.removeAt(index);
    try {
      await save();
    } catch (_) {
      maps.insert(index, removed);
      rethrow;
    }
    final pdf = File(pdfPath(map));
    if (await pdf.exists()) await pdf.delete();
  }

  Future<void> addDxf(DxfImport d) async {
    dxfImports.add(d);
    try {
      await save();
    } catch (_) {
      dxfImports.remove(d);
      rethrow;
    }
  }

  Future<void> removeDxf(DxfImport d) async {
    final index = dxfImports.indexWhere((x) => x.id == d.id);
    if (index < 0) return;
    final removed = dxfImports.removeAt(index);
    try {
      await save();
    } catch (_) {
      dxfImports.insert(index, removed);
      rethrow;
    }
    for (final p in [dxfPath(d), dxfCachePath(d)]) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
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
  // Open documents, cached by path: re-parsing the xref on every render
  // was the dominant cost of the detail overlay. Insertion-ordered for
  // LRU eviction; a doc is only evicted (disposed) when no render is
  // using it, so parallel renders of different PDFs are safe.
  final Map<String, PdfDocument> _docCache = {};
  final Map<String, int> _docRefs = {};
  static const _maxCachedDocs = 3;

  Future<PdfDocument> _openDoc(String pdfPath) async {
    final hit = _docCache[pdfPath];
    if (hit != null) {
      _docRefs[pdfPath] = (_docRefs[pdfPath] ?? 0) + 1;
      // Refresh MRU position (Dart maps are insertion-ordered).
      _docCache.remove(pdfPath);
      _docCache[pdfPath] = hit;
      return hit;
    }
    final doc = await PdfDocument.openFile(pdfPath);
    _docCache[pdfPath] = doc;
    _docRefs[pdfPath] = 1;
    while (_docCache.length > _maxCachedDocs) {
      final victim = _docCache.keys.firstWhere(
        (k) => (_docRefs[k] ?? 0) == 0,
        orElse: () => '',
      );
      if (victim.isEmpty) break; // all in use; keep them for now
      await _docCache.remove(victim)?.dispose();
      _docRefs.remove(victim);
    }
    return doc;
  }

  void _releaseDoc(String pdfPath) {
    final n = (_docRefs[pdfPath] ?? 0) - 1;
    if (n <= 0) {
      _docRefs.remove(pdfPath);
    } else {
      _docRefs[pdfPath] = n;
    }
  }

  /// Renders [pageIndex] of the PDF at [pdfPath] at [dpi], returning the
  /// PNG bytes plus the WGS84 corner coordinates for a map image source.
  ///
  /// Large pages are capped so the bitmap stays under ~2048px on its long
  /// edge (memory safety on real devices); v2 will tile instead.
  Future<PageOverlay> renderPage({
    required String pdfPath,
    required PageGeoref georef,
    double dpi = 150,
  }) =>
      _render(pdfPath: pdfPath, georef: georef, dpi: dpi, maxEdge: 2048);

  /// Renders a small preview of the page for library thumbnails.
  /// The long edge is capped at [maxEdge] px; no georef corners are
  /// returned (null), only the PNG bytes matter.
  Future<Uint8List> renderThumbnail({
    required String pdfPath,
    required PageGeoref georef,
    double maxEdge = 320,
  }) async {
    final overlay = await _render(
      pdfPath: pdfPath,
      georef: georef,
      dpi: 150,
      maxEdge: maxEdge,
    );
    return overlay.pngBytes;
  }

  Future<PageOverlay> _render({
    required String pdfPath,
    required PageGeoref georef,
    required double dpi,
    required double maxEdge,
  }) async {
    final doc = await _openDoc(pdfPath);
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
        final png = await _encodePng(image.width, image.height, image.pixels);
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
      _releaseDoc(pdfPath);
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
    final doc = await _openDoc(pdfPath);
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
        final png = await _encodePng(image.width, image.height, image.pixels);
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
      _releaseDoc(pdfPath);
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

    // Parse the picked file first: a PDF with no georeferencing (or a
    // corrupt file) fails before any copy is made, so failed imports
    // leave no orphan behind — and the file is only read once.
    onProgress('Reading PDF structure…');
    final bytes = await File(sourcePath).readAsBytes();
    final parser = PdfParser.parse(bytes);

    onProgress('Extracting georeferencing…');
    final extractor = GeorefExtractor(parser);
    final georefs = extractor.extractAll();
    if (georefs.isEmpty) {
      throw StateError(
        'No georeferencing found in this PDF. Patok reads OGC '
        'georegistration (/VP /Measure) and TerraGo (/LGIDict) maps.',
      );
    }

    onProgress('Copying file…');
    // The maps dir is normally created by _appDir(), but the app-dir
    // future is cached, so re-create it here if it ever went missing.
    await dest.parent.create(recursive: true);
    await File(sourcePath).copy(dest.path);
    GeoMap map;
    try {
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

      map = GeoMap(
        id: id,
        name: fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), ''),
        fileName: fileName,
        pages: pages,
        // Pages whose georeferencing was broken are skipped, not fatal —
        // carry the reasons on the result so the import screen can tell
        // the user instead of silently dropping them.
        skippedPages: List<String>.of(extractor.pageErrors),
      );
      onProgress('Saving to library…');
      await _library.add(map);
    } catch (_) {
      // The import failed after the copy: remove the orphaned file.
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}
      rethrow;
    }
    // Best-effort library thumbnail; a failure here never fails the import.
    try {
      final png = await _render.renderThumbnail(
        pdfPath: dest.path,
        georef: map.pages.first.georef,
      );
      final thumb = File('${dir.path}/thumbs/$id.png');
      await thumb.parent.create(recursive: true);
      await thumb.writeAsBytes(png);
    } catch (_) {}
    return map;
  }

  /// Lets the user pick a DXF and parses it (no CRS yet). Returns null if
  /// the user cancelled. The CRS choice + transform happen in
  /// [commitDxfImport].
  Future<DxfParseResult?> pickAndParseDxf(
    void Function(String message) onProgress,
  ) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['dxf'],
    );
    if (files.isEmpty) return null;
    final path = files.single.path;
    if (path == null) throw StateError('Picked file has no path');
    onProgress('Parsing DXF…');
    // Parsing runs on a background isolate: a multi-MB DXF used to
    // freeze the UI for seconds, and the progress UI never painted.
    final parsed = await compute(parseDxfFile, path);
    if (parsed.doc.entities.isEmpty) {
      throw StateError(
        'No supported entities found in this DXF. Patok reads LINE, '
        'LWPOLYLINE/POLYLINE, POINT, TEXT, CIRCLE, ARC, HATCH and INSERT.',
      );
    }
    return parsed;
  }

  /// Transforms a parsed DXF into lon/lat with [crs], writes the geometry
  /// cache + a copy of the source file, and registers the import.
  Future<DxfImport> commitDxfImport({
    required DxfParseResult parsed,
    required DxfCrs crs,
    required String name,
    required void Function(String message) onProgress,
  }) async {
    final dir = await _appDir();
    final id = _uuid.v4();

    onProgress('Copying file…');
    final dxfDir = Directory('${dir.path}/dxf');
    if (!await dxfDir.exists()) await dxfDir.create(recursive: true);
    final dxfFile = File('${dxfDir.path}/$id.dxf');
    final cacheFile = File('${dxfDir.path}/$id.json');
    await File(parsed.sourcePath).copy(dxfFile.path);

    try {
      // Projection runs on a background isolate so the progress UI
      // paints and the app stays responsive on large drawings. The
      // per-500-entity progress callback can't cross isolates, so the
      // sheet shows an indeterminate "Projecting geometry…" instead.
      onProgress('Projecting geometry…');
      final projected = await compute(
        _projectDxfFeatures,
        _DxfProjectArgs(doc: parsed.doc, crsJson: crs.toJson()),
      );
      final features = projected.features;
      final bounds = projected.bounds;
      if (features.isEmpty) {
        throw StateError('Nothing renderable survived the projection.');
      }

      onProgress('Writing cache…');
      await writeDxfCache(dir, id, features);

      final imp = DxfImport(
        id: id,
        name: name,
        fileName: parsed.fileName,
        crs: crs,
        bounds: bounds,
        cadLayers: {for (final k in features.keys) k: true},
      );
      onProgress('Saving to library…');
      await _library.addDxf(imp);
      return imp;
    } catch (_) {
      // Projection, cache write or library save failed: remove the
      // copied source (and any partial cache) so a failed import leaves
      // no orphan files behind.
      for (final f in [dxfFile, cacheFile]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }
}

/// Arguments for [_projectDxfFeatures]: plain data only, so they can
/// cross to a background isolate. The CRS travels as JSON — its proj4
/// [Projection] object is not isolate-sendable — and is rebuilt inside
/// the isolate.
class _DxfProjectArgs {
  _DxfProjectArgs({required this.doc, required this.crsJson});
  final DxfDocument doc;
  final Map<String, dynamic> crsJson;
}

class _ProjectedDxf {
  _ProjectedDxf(this.features, this.bounds);
  final Map<String, List<Map<String, dynamic>>> features;
  final List<double> bounds;
}

_ProjectedDxf _projectDxfFeatures(_DxfProjectArgs args) {
  final bounds = <double>[];
  final features = buildDxfFeatures(
    args.doc,
    DxfCrs.fromJson(args.crsJson),
    bounds,
  );
  return _ProjectedDxf(features, bounds);
}

/// Small page previews for library cards, cached on disk under
/// `<appDir>/thumbs/<mapId>.png`.
class ThumbnailService {
  ThumbnailService(this._render);
  final RenderService _render;

  /// File backing the cached library thumbnail for [mapId]
  /// (may not exist yet).
  Future<File> thumbnailFile(String mapId) async {
    final dir = await _appDir();
    return File('${dir.path}/thumbs/$mapId.png');
  }

  /// Returns the cached thumbnail, generating it on first use (backfill
  /// for maps imported before thumbnails existed). Returns null when the
  /// map has no pages or rendering fails — callers fall back to an icon.
  Future<File?> ensureThumbnail(GeoMap map) async {
    try {
      final file = await thumbnailFile(map.id);
      if (await file.exists()) return file;
      if (map.pages.isEmpty) return null;
      final dir = await _appDir();
      final pdf = File('${dir.path}/${map.relativePdfPath}');
      if (!await pdf.exists()) return null;
      final png = await _render.renderThumbnail(
        pdfPath: pdf.path,
        georef: map.pages.first.georef,
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png);
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteThumbnail(String mapId) async {
    try {
      final file = await thumbnailFile(mapId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// GPS location via geolocator (works fully offline; network only
/// speeds up the first fix).
class LocationService {
  /// Called when location permission becomes granted (first grant or
  /// already granted). Wired in main.dart to restart the GNSS stream,
  /// which cannot start before permission exists.
  void Function()? onPermissionGranted;

  Future<bool> ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    final granted = perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
    if (granted) onPermissionGranted?.call();
    return granted;
  }

  /// A last-known fix older than [maxLastKnownAge] is worse than none:
  /// grid reference points and waypoints would silently use a fix from
  /// hours or days ago.
  Future<Position?> currentPosition({
    Duration maxLastKnownAge = const Duration(seconds: 60),
  }) async {
    if (!await ensurePermission()) return null;
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return null;
      if (DateTime.now().difference(last.timestamp) > maxLastKnownAge) {
        return null;
      }
      return last;
    }
  }

  // The platform streams run only while someone is listening (or while
  // explicitly started): the old cached streams ran at best accuracy
  // for the whole app lifetime, even on other tabs. Listeners get a
  // shared broadcast stream; [stopPositionUpdates]/[stopRawPositionUpdates]
  // pause the native updates while listeners stay attached (e.g. the
  // map tab is hidden), and the matching start methods resume them.
  StreamController<Position>? _positionController;
  StreamSubscription<Position>? _positionSub;
  bool _positionStopped = false;

  StreamController<Position>? _rawController;
  StreamSubscription<Position>? _rawSub;
  bool _rawStopped = false;

  Stream<Position> positionStream() {
    _positionController ??= StreamController<Position>.broadcast(
      onListen: () {
        if (!_positionStopped) _startPositionUpdates();
      },
      onCancel: _stopPositionUpdates,
    );
    return _positionController!.stream;
  }

  void _startPositionUpdates() {
    if (_positionSub != null) return;
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 2,
      ),
    ).listen(
      (p) => _positionController?.add(p),
      onError: (_) {},
    );
  }

  void _stopPositionUpdates() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  /// Stops GPS updates even while listeners are attached.
  /// Call [startPositionUpdates] to resume.
  void stopPositionUpdates() {
    _positionStopped = true;
    _stopPositionUpdates();
  }

  void startPositionUpdates() {
    _positionStopped = false;
    if (_positionController?.hasListener ?? false) {
      _startPositionUpdates();
    }
  }

  /// Time-based stream (no distance filter) for stationary work like
  /// waypoint averaging — the main stream goes quiet when not moving.
  Stream<Position> rawPositionStream() {
    _rawController ??= StreamController<Position>.broadcast(
      onListen: () {
        if (!_rawStopped) _startRawPositionUpdates();
      },
      onCancel: _stopRawPositionUpdates,
    );
    return _rawController!.stream;
  }

  void _startRawPositionUpdates() {
    if (_rawSub != null) return;
    _rawSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      ),
    ).listen(
      (p) => _rawController?.add(p),
      onError: (_) {},
    );
  }

  void _stopRawPositionUpdates() {
    _rawSub?.cancel();
    _rawSub = null;
  }

  /// Stops the time-based stream even while listeners are attached.
  /// Call [startRawPositionUpdates] to resume.
  void stopRawPositionUpdates() {
    _rawStopped = true;
    _stopRawPositionUpdates();
  }

  void startRawPositionUpdates() {
    _rawStopped = false;
    if (_rawController?.hasListener ?? false) {
      _startRawPositionUpdates();
    }
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

  /// When the current recording started (null when idle).
  DateTime? startTime;

  /// Elapsed recording time (zero when idle).
  Duration get elapsed => startTime == null
      ? Duration.zero
      : DateTime.now().difference(startTime!);

  /// Live (lon, lat) points while recording; empty when idle.
  /// Fixes append to the persistent point list and the notifier is
  /// given a fresh unmodifiable *view* of it: a view is O(1) to
  /// create (no element copy), unlike the old full copy per fix.
  final ValueNotifier<List<List<double>>> livePoints = ValueNotifier(const []);

  StreamSubscription<Position>? _sub;
  final List<List<double>> _points = [];

  static const _trackChannel = MethodChannel('patok/track');

  /// Keeps the foreground service in sync with the recording state, so
  /// fixes keep flowing while the phone is locked. A missing native
  /// handler (unit tests) is ignored: recording still works without it.
  Future<void> _setForegroundTracking(bool active) async {
    try {
      await _trackChannel.invokeMethod(active ? 'start' : 'stop');
    } catch (_) {}
  }

  Future<void> start() async {
    if (isRecording.value) return;
    if (!await _locationService.ensurePermission()) {
      throw StateError('Location permission denied');
    }
    _points.clear();
    pointCount.value = 0;
    livePoints.value = UnmodifiableListView<List<double>>(_points);
    // The stream may be paused because the map tab is hidden; recording
    // needs live fixes wherever it is started from, so resume first.
    _locationService.startPositionUpdates();
    _sub = _locationService.positionStream().listen(
      (p) {
        _points.add([p.longitude, p.latitude]);
        pointCount.value = _points.length;
        livePoints.value = UnmodifiableListView<List<double>>(_points);
      },
      onError: (_) {
        // The platform stream died (e.g. permission revoked): stop
        // collecting so the recording state doesn't lie, but keep the
        // points so stop() can still save the partial track.
        _sub?.cancel();
        _sub = null;
        isRecording.value = false;
        startTime = null;
        _setForegroundTracking(false);
      },
    );
    startTime = DateTime.now();
    isRecording.value = true;
    _setForegroundTracking(true);
  }

  /// Stops recording and returns the track as a [Measurement], or null
  /// when too few points were collected.
  Future<Measurement?> stop(String name) async {
    await _sub?.cancel();
    _sub = null;
    isRecording.value = false;
    startTime = null;
    _setForegroundTracking(false);
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
    startTime = null;
    _setForegroundTracking(false);
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

  /// Render DPI for map overlays (96 / 150 / 300). Out-of-range values
  /// (e.g. from a corrupt prefs file) are clamped, never trusted.
  double get renderDpi {
    final v = _prefs.getDouble('renderDpi') ?? 150;
    return v.clamp(96, 300).toDouble();
  }

  Future<void> setRenderDpi(double v) =>
      _prefs.setDouble('renderDpi', v.clamp(96, 300).toDouble());

  /// 'utm' or 'latlon'.
  String get coordFormat => _prefs.getString('coordFormat') ?? 'utm';
  Future<void> setCoordFormat(String v) => _prefs.setString('coordFormat', v);

  bool get showUtmGrid => _prefs.getBool('showUtmGrid') ?? false;
  Future<void> setShowUtmGrid(bool v) => _prefs.setBool('showUtmGrid', v);

  /// High-detail re-render of the visible map region when zoomed in
  /// (keeps PDF text sharp like a native viewer). Default on.
  bool get detailZoom => _prefs.getBool('detailZoom') ?? true;
  Future<void> setDetailZoom(bool v) => _prefs.setBool('detailZoom', v);

  /// Last DXF import UTM zone/hemisphere (remembered for next import).
  /// Zones are 1..60; out-of-range values are clamped, never trusted.
  int get lastDxfUtmZone {
    final z = _prefs.getInt('lastDxfUtmZone') ?? 50;
    return z.clamp(1, 60);
  }

  bool get lastDxfUtmSouth => _prefs.getBool('lastDxfUtmSouth') ?? true;
  Future<void> setLastDxfUtm(int zone, bool south) async {
    await _prefs.setInt('lastDxfUtmZone', zone.clamp(1, 60));
    await _prefs.setBool('lastDxfUtmSouth', south);
  }
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
    }, onError: (_) {
      // The native side errors when location permission is missing
      // (SecurityException). The stream is dead after an error, so
      // clear the subscription: a later ensureStarted() can retry
      // instead of the count staying blank for the whole session.
      _sub = null;
    });
  }

  /// Starts the stream if it isn't running. The first start() happens
  /// in main() before any permission exists and dies silently; this is
  /// the retry path, called once permission is granted.
  void ensureStarted() => start();

  /// Restarts the stream (stop + start).
  void restart() {
    stop();
    start();
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    // Don't keep a stale satellite count after stopping.
    satellites.value = null;
  }
}

/// Simple JSON store for waypoints and measurements.
class FieldDataStore {
  FieldDataStore._(this._dir);
  final Directory _dir;

  final _SaveQueue _saveQueue = _SaveQueue();

  static Future<FieldDataStore> load() async =>
      FieldDataStore._(await _appDir());

  Future<List<Waypoint>> waypoints() async {
    final f = File('${_dir.path}/waypoints.json');
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      // Per-entry tolerance: one corrupt waypoint must not wipe the rest.
      final out = <Waypoint>[];
      for (final j in list) {
        try {
          out.add(Waypoint.fromJson(j as Map<String, dynamic>));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWaypoints(List<Waypoint> wps) {
    // Snapshot: the caller may keep mutating its list while the write
    // is queued behind another save.
    final snapshot = List<Waypoint>.of(wps);
    return _saveQueue.run(() async {
      final f = File('${_dir.path}/waypoints.json');
      await _writeFileAtomic(
        f,
        jsonEncode(snapshot.map((w) => w.toJson()).toList()),
      );
    });
  }

  Future<List<Measurement>> measurements() async {
    final f = File('${_dir.path}/measurements.json');
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      final out = <Measurement>[];
      for (final j in list) {
        try {
          out.add(Measurement.fromJson(j as Map<String, dynamic>));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMeasurements(List<Measurement> ms) {
    final snapshot = List<Measurement>.of(ms);
    return _saveQueue.run(() async {
      final f = File('${_dir.path}/measurements.json');
      await _writeFileAtomic(
        f,
        jsonEncode(snapshot.map((m) => m.toJson()).toList()),
      );
    });
  }
}
