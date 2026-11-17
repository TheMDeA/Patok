/// DXF library entries: the transformed-geometry cache format and the
/// import pipeline (parse -> project to lon/lat -> write cache).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'dxf_crs.dart';
import 'dxf_model.dart';
import 'dxf_parser.dart';

/// One imported DXF drawing in the library.
class DxfImport {
  DxfImport({
    required this.id,
    required this.name,
    required this.fileName,
    required this.crs,
    required this.bounds,
    Map<String, bool>? cadLayers,
    this.visible = true,
    this.opacity = 1.0,
    DateTime? addedAt,
  })  : cadLayers = cadLayers ?? {},
        addedAt = addedAt ?? DateTime.now();

  final String id;
  String name;
  final String fileName;
  DxfCrs crs;
  bool visible;
  double opacity;

  /// CAD layer name -> visible. Keys double as the layer list.
  final Map<String, bool> cadLayers;

  /// [minLon, minLat, maxLon, maxLat] in WGS84.
  final List<double> bounds;

  final DateTime addedAt;

  String get relativeDxfPath => 'dxf/$id.dxf';
  String get relativeCachePath => 'dxf/$id.json';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'fileName': fileName,
        'crs': crs.toJson(),
        'visible': visible,
        'opacity': opacity,
        'cadLayers': cadLayers,
        'bounds': bounds,
        'addedAt': addedAt.toIso8601String(),
      };

  factory DxfImport.fromJson(Map<String, dynamic> j) => DxfImport(
        id: j['id'] as String,
        name: j['name'] as String,
        fileName: j['fileName'] as String,
        crs: DxfCrs.fromJson(j['crs'] as Map<String, dynamic>),
        visible: j['visible'] as bool? ?? true,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
        cadLayers: (j['cadLayers'] as Map?)?.map(
              (k, v) => MapEntry(k as String, v as bool),
            ) ??
            {},
        bounds: (j['bounds'] as List)
            .map((v) => (v as num).toDouble())
            .toList(),
        addedAt: DateTime.parse(j['addedAt'] as String),
      );
}

/// Result of picking + parsing a DXF, before the CRS is chosen.
class DxfParseResult {
  DxfParseResult({
    required this.sourcePath,
    required this.fileName,
    required this.doc,
  });
  final String sourcePath;
  final String fileName;
  final DxfDocument doc;

  int get entityCount => doc.entities.length;
}

/// Transforms every entity of [doc] into lon/lat GeoJSON features grouped
/// by CAD layer name. Appends the WGS84 bounds to [boundsOut]
/// ([minLon, minLat, maxLon, maxLat]). Colors come from the LAYER table.
Map<String, List<Map<String, dynamic>>> buildDxfFeatures(
  DxfDocument doc,
  DxfCrs crs,
  List<double> boundsOut, {
  void Function(int done, int total)? onProgress,
}) {
  final byLayer = <String, List<Map<String, dynamic>>>{};
  var minLon = double.infinity;
  var minLat = double.infinity;
  var maxLon = -double.infinity;
  var maxLat = -double.infinity;

  (double, double)? proj(DxfPoint p) {
    // A projection can go non-finite for far-out-of-range input (or a
    // degenerate local grid), and proj4 itself throws on non-finite
    // input: drop the point instead of letting it poison the bounds,
    // break the cache's jsonEncode, or fail the whole import.
    if (!p.x.isFinite || !p.y.isFinite) return null;
    double lon, lat;
    try {
      (lon, lat) = crs.toLonLat(p.x, p.y);
    } catch (_) {
      return null;
    }
    if (!lon.isFinite || !lat.isFinite) return null;
    if (lon < minLon) minLon = lon;
    if (lat < minLat) minLat = lat;
    if (lon > maxLon) maxLon = lon;
    if (lat > maxLat) maxLat = lat;
    return (lon, lat);
  }

  // Layer colours are looked up once per CAD layer, not once per feature.
  final colorCache = <String, String>{};
  String colorOf(String layerName) => colorCache.putIfAbsent(layerName, () {
        final idx = doc.layers[layerName]?.colorIndex ?? 7;
        final argb = aciToArgb(idx);
        return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
      });

  void add(String layerName, Map<String, dynamic> geometry, String kind,
      {String? text, double? height}) {
    final color = colorOf(layerName);
    (byLayer[layerName] ??= []).add({
      'type': 'Feature',
      'geometry': geometry,
      'properties': {
        'color': color,
        'kind': kind,
        if (text case final t) 'text': t,
        // Label height in native units; the map sizes labels from it
        // when present and falls back to 12.0 pt for old caches.
        if (height != null && height.isFinite) 'height': height,
      },
    });
  }

  Map<String, dynamic>? lineGeom(List<DxfPoint> pts, {bool close = false}) {
    final coords = <List<double>>[];
    for (final p in pts) {
      final ll = proj(p);
      if (ll == null) return null; // non-finite projection: drop the line
      coords.add([ll.$1, ll.$2]);
    }
    if (close && coords.isNotEmpty) coords.add(coords.first);
    return {
      'type': 'LineString',
      'coordinates': coords,
    };
  }

  final total = doc.entities.length;
  for (var i = 0; i < total; i++) {
    final e = doc.entities[i];
    // Layers turned off in CAD (negative ACI color) are not drawn.
    if (doc.layers[e.layer]?.off ?? false) {
      if (onProgress != null && (i % 500 == 499 || i == total - 1)) {
        onProgress(i + 1, total);
      }
      continue;
    }
    switch (e) {
      case DxfLine(:var a, :var b):
        final g = lineGeom([a, b]);
        if (g != null) add(e.layer, g, 'line');
      case DxfPolyline(:var vertices, :var closed):
        if (vertices.length >= 2) {
          final g = lineGeom(vertices, close: closed);
          if (g != null) add(e.layer, g, 'line');
        }
      case DxfCircle():
        final g = lineGeom(e.toRing(), close: true);
        if (g != null) add(e.layer, g, 'line');
      case DxfArc():
        final pts = e.toPolyline();
        if (pts.length >= 2) {
          final g = lineGeom(pts);
          if (g != null) add(e.layer, g, 'line');
        }
      case DxfHatch(:var loops):
        final rings = <List<List<double>>>[];
        for (final loop in loops) {
          final ring = <List<double>>[];
          for (final p in loop) {
            final ll = proj(p);
            if (ll != null) ring.add([ll.$1, ll.$2]);
          }
          if (ring.length >= 4) {
            if (ring.first[0] != ring.last[0] ||
                ring.first[1] != ring.last[1]) {
              ring.add(ring.first);
            }
            rings.add(ring);
          }
        }
        if (rings.isNotEmpty) {
          // Disjoint islands become separate polygons; rings inside
          // another ring are holes of it (see _groupHatchRings).
          for (final poly in _groupHatchRings(rings)) {
            add(e.layer, {'type': 'Polygon', 'coordinates': poly}, 'fill');
          }
        }
      case DxfPointEntity(:var position):
        final ll = proj(position);
        if (ll != null) {
          add(
            e.layer,
            {
              'type': 'Point',
              'coordinates': [ll.$1, ll.$2],
            },
            'point',
          );
        }
      case DxfText(:var position, :var text, :var height):
        final ll = proj(position);
        if (ll != null) {
          add(
            e.layer,
            {
              'type': 'Point',
              'coordinates': [ll.$1, ll.$2],
            },
            'label',
            text: text,
            height: height,
          );
        }
    }
    if (onProgress != null && (i % 500 == 499 || i == total - 1)) {
      onProgress(i + 1, total);
    }
  }
  // Drop CAD layers that ended up with no renderable features.
  byLayer.removeWhere((_, v) => v.isEmpty);
  // Only report bounds when at least one point projected successfully.
  if (minLon.isFinite) boundsOut.addAll([minLon, minLat, maxLon, maxLat]);
  return byLayer;
}

double _ringArea(List<List<double>> ring) {
  var sum = 0.0;
  for (var i = 0; i < ring.length; i++) {
    final p = ring[i];
    final q = ring[(i + 1) % ring.length];
    sum += p[0] * q[1] - q[0] * p[1];
  }
  return sum / 2;
}

/// Groups HATCH rings into polygons: a ring's parent is the smallest ring
/// containing one of its points, so nesting depth decides its role —
/// even depth is an exterior, odd depth a hole of its nearest exterior.
/// Disjoint islands therefore become separate polygons instead of the
/// second island rendering as a hole. Winding is normalized (exteriors
/// counter-clockwise, holes clockwise) per the GeoJSON right-hand rule.
List<List<List<List<double>>>> _groupHatchRings(
    List<List<List<double>>> rings) {
  final n = rings.length;
  final parent = List<int?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    final areaI = _ringArea(rings[i]).abs();
    var bestArea = double.infinity;
    for (var j = 0; j < n; j++) {
      if (i == j) continue;
      final areaJ = _ringArea(rings[j]).abs();
      if (areaJ <= areaI || areaJ >= bestArea) continue;
      if (_pointInRing(rings[i].first, rings[j])) {
        bestArea = areaJ;
        parent[i] = j;
      }
    }
  }

  int depth(int i) {
    var d = 0;
    var p = parent[i];
    while (p != null) {
      d++;
      p = parent[p];
    }
    return d;
  }

  final polys = <List<List<List<double>>>>[];
  final exteriorIndex = <int, int>{};
  for (var i = 0; i < n; i++) {
    if (depth(i) % 2 == 0) {
      exteriorIndex[i] = polys.length;
      polys.add([_orientRing(rings[i], positive: true)]);
    }
  }
  for (var i = 0; i < n; i++) {
    if (depth(i) % 2 == 1) {
      // A hole's parent is always an exterior (depth one less).
      final pi = exteriorIndex[parent[i]];
      if (pi != null) polys[pi].add(_orientRing(rings[i], positive: false));
    }
  }
  return polys;
}

/// Ray-casting point-in-polygon test (rings are closed, first == last).
bool _pointInRing(List<double> pt, List<List<double>> ring) {
  final x = pt[0];
  final y = pt[1];
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i][0];
    final yi = ring[i][1];
    final xj = ring[j][0];
    final yj = ring[j][1];
    if ((yi > y) != (yj > y) &&
        x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Returns [ring] with the requested winding (positive = counter-
/// clockwise). The input ring is not modified.
List<List<double>> _orientRing(List<List<double>> ring,
    {required bool positive}) {
  final area = _ringArea(ring);
  if ((positive && area < 0) || (!positive && area > 0)) {
    return ring.reversed.toList();
  }
  return ring;
}

/// Parses a DXF file from [sourcePath].
/// The file is streamed (64 KB chunks, incremental UTF-8 decode), so a
/// multi-MB drawing is never held whole in memory.
DxfParseResult parseDxfFile(String sourcePath) {
  final fileName = sourcePath.split(Platform.pathSeparator).last;
  return DxfParseResult(
    sourcePath: sourcePath,
    fileName: fileName,
    doc: parseDxfLines(dxfFileLines(File(sourcePath))),
  );
}

/// Writes the transformed feature cache for a DXF import.
Future<void> writeDxfCache(
  Directory appDir,
  String id,
  Map<String, List<Map<String, dynamic>>> features,
) async {
  final dir = Directory('${appDir.path}/dxf');
  if (!await dir.exists()) await dir.create(recursive: true);
  await File('${dir.path}/$id.json').writeAsString(jsonEncode(features));
}

/// Reads a DXF feature cache: CAD layer name -> GeoJSON features.
/// The JSON decode runs on a background isolate so opening a map with a
/// large drawing doesn't freeze the UI thread.
Future<Map<String, List<Map<String, dynamic>>>> readDxfCache(
  String cachePath,
) async {
  final raw = await File(cachePath).readAsString();
  return compute(_decodeDxfCache, raw);
}

Map<String, List<Map<String, dynamic>>> _decodeDxfCache(String raw) {
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  return decoded.map((k, v) => MapEntry(
        k,
        (v as List).map((e) => e as Map<String, dynamic>).toList(),
      ));
}

/// Splits an import's features into chunks that each stay comfortably
/// under the ~1MB Android method-channel limit when serialized as
/// GeoJSON (one map source per chunk). Deterministic: the same cache
/// always chunks the same way.
List<Map<String, List<Map<String, dynamic>>>> chunkDxfFeatures(
  Map<String, List<Map<String, dynamic>>> byCadLayer, {
  int maxBytes = 400 * 1024,
}) {
  final chunks = <Map<String, List<Map<String, dynamic>>>>[];
  var cur = <String, List<Map<String, dynamic>>>{};
  var curBytes = 0;
  void flush() {
    if (cur.isEmpty) return;
    chunks.add(cur);
    cur = <String, List<Map<String, dynamic>>>{};
    curBytes = 0;
  }

  final layers = byCadLayer.keys.toList()..sort();
  for (final layer in layers) {
    for (final f in byCadLayer[layer]!) {
      final est = estimateFeatureBytes(f);
      if (est > maxBytes) {
        // One oversize feature (e.g. a contour with tens of thousands of
        // vertices) is split across chunks instead of going out whole.
        for (final part in _splitFeature(f, maxBytes)) {
          final pest = estimateFeatureBytes(part);
          if (curBytes + pest > maxBytes && curBytes > 0) flush();
          (cur[layer] ??= []).add(part);
          curBytes += pest;
        }
        continue;
      }
      if (curBytes + est > maxBytes && curBytes > 0) flush();
      (cur[layer] ??= []).add(f);
      curBytes += est;
    }
  }
  flush();
  return chunks;
}

/// Splits one oversize feature into pieces that each fit in [maxBytes].
/// LineStrings are cut into consecutive coordinate runs (sharing the
/// boundary point so no segment is lost); Polygons are split per ring,
/// and a single ring that is still too big is cut into chord-closed
/// pieces (an approximate fill, only for pathological rings). Points and
/// labels are never oversize and pass through unchanged.
List<Map<String, dynamic>> _splitFeature(
    Map<String, dynamic> f, int maxBytes) {
  final geom = f['geometry'] as Map;
  final type = geom['type'] as String;
  final props = f['properties'] as Map;
  Map<String, dynamic> piece(Map<String, dynamic> geometry) => {
        'type': 'Feature',
        'geometry': geometry,
        'properties': props,
      };
  // Coordinate budget per piece, from the same estimate as the chunker.
  final budget = ((maxBytes - 150) / 24).floor().clamp(2, 1 << 30);
  if (type == 'LineString') {
    final coords = (geom['coordinates'] as List).cast<List>();
    if (coords.length < 2) return [f];
    final out = <Map<String, dynamic>>[];
    var i = 0;
    while (i < coords.length - 1) {
      final end = (i + budget).clamp(0, coords.length);
      out.add(piece({
        'type': 'LineString',
        'coordinates': coords.sublist(i, end),
      }));
      if (end >= coords.length) break;
      i = end - 1; // share the boundary point with the next piece
    }
    return out.isEmpty ? [f] : out;
  }
  if (type == 'Polygon') {
    final rings = (geom['coordinates'] as List).cast<List>();
    final out = <Map<String, dynamic>>[];
    for (final ring in rings) {
      final coords = ring.cast<List>();
      if (24 * coords.length + 150 <= maxBytes) {
        out.add(piece({
          'type': 'Polygon',
          'coordinates': [coords],
        }));
      } else {
        var i = 0;
        while (i < coords.length) {
          final end = (i + budget).clamp(0, coords.length);
          final part = coords.sublist(i, end);
          if (part.length >= 3) {
            out.add(piece({
              'type': 'Polygon',
              'coordinates': [
                [...part, part.first]
              ],
            }));
          }
          i = end;
        }
      }
    }
    return out.isEmpty ? [f] : out;
  }
  return [f];
}

/// Cheap size estimate for one GeoJSON feature: coordinates dominate.
/// One coordinate pair serializes to ~24 bytes ("[115.123456,-2.123456]").
int estimateFeatureBytes(Map<String, dynamic> f) =>
    24 * _coordPairCount((f['geometry'] as Map)['coordinates']) + 150;

/// Counts coordinate *pairs* ([lon, lat]) in a nested coordinate array.
int _coordPairCount(dynamic coords) {
  if (coords is List) {
    if (coords.length == 2 && coords[0] is num && coords[1] is num) {
      return 1;
    }
    var n = 0;
    for (final c in coords) {
      n += _coordPairCount(c);
    }
    return n;
  }
  return 0;
}
