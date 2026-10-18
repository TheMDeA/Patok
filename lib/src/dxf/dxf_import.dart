/// DXF library entries: the transformed-geometry cache format and the
/// import pipeline (parse -> project to lon/lat -> write cache).
library;

import 'dart:convert';
import 'dart:io';

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

  (double, double) proj(DxfPoint p) {
    final (lon, lat) = crs.toLonLat(p.x, p.y);
    if (lon < minLon) minLon = lon;
    if (lat < minLat) minLat = lat;
    if (lon > maxLon) maxLon = lon;
    if (lat > maxLat) maxLat = lat;
    return (lon, lat);
  }

  String colorOf(String layerName) {
    final idx = doc.layers[layerName]?.colorIndex ?? 7;
    final argb = aciToArgb(idx);
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  void add(String layerName, Map<String, dynamic> geometry, String kind,
      {String? text}) {
    final color = colorOf(layerName);
    (byLayer[layerName] ??= []).add({
      'type': 'Feature',
      'geometry': geometry,
      'properties': {
        'color': color,
        'kind': kind,
        if (text case final t) 'text': t,
      },
    });
  }

  Map<String, dynamic> lineGeom(List<DxfPoint> pts, {bool close = false}) {
    List<double> pc(DxfPoint p) {
      final (lon, lat) = proj(p);
      return [lon, lat];
    }

    final coords = [for (final p in pts) pc(p)];
    if (close && coords.isNotEmpty) coords.add(coords.first);
    return {
      'type': 'LineString',
      'coordinates': coords,
    };
  }

  final total = doc.entities.length;
  for (var i = 0; i < total; i++) {
    final e = doc.entities[i];
    switch (e) {
      case DxfLine(:var a, :var b):
        add(e.layer, lineGeom([a, b]), 'line');
      case DxfPolyline(:var vertices, :var closed):
        if (vertices.length >= 2) {
          add(e.layer, lineGeom(vertices, close: closed), 'line');
        }
      case DxfCircle():
        add(e.layer, lineGeom(e.toRing(), close: true), 'line');
      case DxfArc():
        final pts = e.toPolyline();
        if (pts.length >= 2) add(e.layer, lineGeom(pts), 'line');
      case DxfHatch(:var loops):
        final rings = <List<List<double>>>[];
        for (final loop in loops) {
          final ring = <List<double>>[];
          for (final p in loop) {
            final (lon, lat) = proj(p);
            ring.add([lon, lat]);
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
          // Largest ring first = exterior; the rest are holes.
          rings.sort((a, b) =>
              _ringArea(b).abs().compareTo(_ringArea(a).abs()));
          add(e.layer, {'type': 'Polygon', 'coordinates': rings}, 'fill');
        }
      case DxfPointEntity(:var position):
        final (lon, lat) = proj(position);
        add(
          e.layer,
          {
            'type': 'Point',
            'coordinates': [lon, lat],
          },
          'point',
        );
      case DxfText(:var position, :var text):
        final (lon, lat) = proj(position);
        add(
          e.layer,
          {
            'type': 'Point',
            'coordinates': [lon, lat],
          },
          'label',
          text: text,
        );
    }
    if (onProgress != null && (i % 500 == 499 || i == total - 1)) {
      onProgress(i + 1, total);
    }
  }
  // Drop CAD layers that ended up with no renderable features.
  byLayer.removeWhere((_, v) => v.isEmpty);
  boundsOut.addAll([minLon, minLat, maxLon, maxLat]);
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

/// Parses a DXF file from [sourcePath].
DxfParseResult parseDxfFile(String sourcePath) {
  final content = File(sourcePath).readAsStringSync();
  final fileName = sourcePath.split(Platform.pathSeparator).last;
  return DxfParseResult(
    sourcePath: sourcePath,
    fileName: fileName,
    doc: parseDxf(content),
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
Future<Map<String, List<Map<String, dynamic>>>> readDxfCache(
  String cachePath,
) async {
  final f = File(cachePath);
  final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  return raw.map((k, v) => MapEntry(
        k,
        (v as List).map((e) => e as Map<String, dynamic>).toList(),
      ));
}
