import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/dxf/dxf_crs.dart';
import 'package:patok/src/dxf/dxf_import.dart';
import 'package:patok/src/dxf/dxf_model.dart';
import 'package:patok/src/dxf/dxf_parser.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

const _dxf = '''
0
SECTION
2
TABLES
0
TABLE
2
LAYER
0
LAYER
2
PIT
62
1
0
LAYER
2
LABELS
62
3
0
ENDTAB
0
ENDSEC
0
SECTION
2
ENTITIES
0
LINE
8
PIT
10
500000.0
20
9760000.0
11
501000.0
21
9761000.0
0
TEXT
8
LABELS
10
500500.0
20
9760500.0
40
2.5
1
Ramp A
0
CIRCLE
8
PIT
10
502000.0
20
9762000.0
40
100.0
0
HATCH
8
PIT
91
1
92
2
93
4
10
503000.0
20
9763000.0
10
504000.0
20
9763000.0
10
504000.0
20
9764000.0
10
503000.0
20
9764000.0
0
POINT
8
PIT
10
505000.0
20
9765000.0
0
ENDSEC
0
EOF
''';

(double, double) _lonLat(double e, double n) {
  final proj = proj4.Projection.parse(
    '+proj=utm +zone=50 +datum=WGS84 +units=m +no_defs +south',
  );
  final p = proj.transform(
    proj4.Projection.WGS84,
    proj4.Point(x: e, y: n),
  );
  return (p.x, p.y);
}

Map<String, dynamic> _lineFeature(int nPts, String color) => {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (var i = 0; i < nPts; i++) [115.0 + i * 0.001, -2.0],
        ],
      },
      'properties': {'color': color, 'kind': 'line'},
    };

void main() {
  test('entities become lon/lat features grouped by CAD layer', () {
    final doc = parseDxf(_dxf);
    final crs = DxfUtm(zone: 50, southernHemisphere: true);
    final bounds = <double>[];
    final features = buildDxfFeatures(doc, crs, bounds);

    expect(features.keys.toSet(), {'PIT', 'LABELS'});
    expect(bounds, hasLength(4));
    expect(bounds[0], lessThan(bounds[2]));
    expect(bounds[1], lessThan(bounds[3]));

    // LINE -> LineString, layer color red (#FF0000).
    final pit = features['PIT']!;
    final line = pit.firstWhere(
        (f) => (f['geometry'] as Map)['type'] == 'LineString');
    expect((line['properties'] as Map)['kind'], 'line');
    expect((line['properties'] as Map)['color'], '#FF0000');
    final coords = (line['geometry'] as Map)['coordinates'] as List;
    expect(coords, hasLength(2));
    final (eLon, eLat) = _lonLat(500000.0, 9760000.0);
    expect(coords[0][0], closeTo(eLon, 1e-9));
    expect(coords[0][1], closeTo(eLat, 1e-9));

    // CIRCLE -> closed LineString ring.
    final rings = pit.where((f) {
      final g = f['geometry'] as Map;
      return g['type'] == 'LineString' &&
          (g['coordinates'] as List).length > 10;
    }).toList();
    expect(rings, hasLength(1));
    final ring = (rings.single['geometry'] as Map)['coordinates'] as List;
    expect(ring.first[0], closeTo(ring.last[0], 1e-12));
    expect(ring.first[1], closeTo(ring.last[1], 1e-12));

    // HATCH -> Polygon with closed exterior ring.
    final fills = pit
        .where((f) => (f['properties'] as Map)['kind'] == 'fill')
        .toList();
    expect(fills, hasLength(1));
    final poly = (fills.single['geometry'] as Map);
    expect(poly['type'], 'Polygon');
    final exterior = (poly['coordinates'] as List).first as List;
    expect(exterior.length, greaterThanOrEqualTo(5));
    expect(exterior.first[0], closeTo(exterior.last[0], 1e-12));

    // POINT -> Point.
    final points = pit
        .where((f) => (f['properties'] as Map)['kind'] == 'point')
        .toList();
    expect(points, hasLength(1));

    // TEXT -> label with text property, green layer color.
    final labels = features['LABELS']!;
    expect(labels, hasLength(1));
    expect((labels.single['properties'] as Map)['kind'], 'label');
    expect((labels.single['properties'] as Map)['text'], 'Ramp A');
    expect((labels.single['properties'] as Map)['color'], '#00FF00');
    // Label height is carried in the feature for the map to size it.
    expect((labels.single['properties'] as Map)['height'], 2.5);
  });

  test('non-finite coordinates are skipped, never break the cache', () {
    final doc = DxfDocument(
      layers: {'PIT': DxfLayer(name: 'PIT', colorIndex: 1)},
      entities: [
        DxfLine(
          layer: 'PIT',
          a: const DxfPoint(500000, 9760000),
          b: const DxfPoint(double.nan, 9761000),
        ),
        DxfLine(
          layer: 'PIT',
          a: const DxfPoint(500000, 9760000),
          b: const DxfPoint(501000, 9761000),
        ),
        DxfPointEntity(
          layer: 'PIT',
          position: const DxfPoint(double.infinity, 0),
        ),
      ],
    );
    final bounds = <double>[];
    final features = buildDxfFeatures(
      doc,
      DxfUtm(zone: 50, southernHemisphere: true),
      bounds,
    );
    // Only the good line survives; bounds stay finite; cache encodes.
    expect(features['PIT'], hasLength(1));
    expect(bounds.every((v) => v.isFinite), isTrue);
    expect(() => jsonEncode(features), returnsNormally);
  });

  test('all-non-finite input yields no features and no bounds', () {
    final doc = DxfDocument(
      layers: {'PIT': DxfLayer(name: 'PIT', colorIndex: 1)},
      entities: [
        DxfLine(
          layer: 'PIT',
          a: const DxfPoint(double.nan, double.nan),
          b: const DxfPoint(double.nan, double.nan),
        ),
      ],
    );
    final bounds = <double>[];
    final features = buildDxfFeatures(
      doc,
      DxfUtm(zone: 50, southernHemisphere: true),
      bounds,
    );
    expect(features, isEmpty);
    expect(bounds, isEmpty);
  });

  test('HATCH with two disjoint loops becomes two polygons', () {
    const hatchDxf = '''
0
SECTION
2
TABLES
0
TABLE
2
LAYER
0
LAYER
2
PIT
62
1
0
ENDTAB
0
ENDSEC
0
SECTION
2
ENTITIES
0
HATCH
8
PIT
91
1
92
2
93
4
10
500000.0
20
9760000.0
10
501000.0
20
9760000.0
10
501000.0
20
9761000.0
10
500000.0
20
9761000.0
91
1
92
2
93
4
10
502000.0
20
9760000.0
10
503000.0
20
9760000.0
10
503000.0
20
9761000.0
10
502000.0
20
9761000.0
0
ENDSEC
0
EOF
''';
    final doc = parseDxf(hatchDxf);
    final features = buildDxfFeatures(
      doc,
      DxfUtm(zone: 50, southernHemisphere: true),
      [],
    );
    final fills = features['PIT']!
        .where((f) => (f['properties'] as Map)['kind'] == 'fill')
        .toList();
    expect(fills, hasLength(2));
    for (final f in fills) {
      expect((f['geometry'] as Map)['type'], 'Polygon');
      expect(((f['geometry'] as Map)['coordinates'] as List), hasLength(1));
    }
  });

  test('HATCH with an inner loop keeps it as a hole', () {
    const hatchDxf = '''
0
SECTION
2
TABLES
0
TABLE
2
LAYER
0
LAYER
2
PIT
62
1
0
ENDTAB
0
ENDSEC
0
SECTION
2
ENTITIES
0
HATCH
8
PIT
91
1
92
2
93
4
10
500000.0
20
9760000.0
10
503000.0
20
9760000.0
10
503000.0
20
9763000.0
10
500000.0
20
9763000.0
91
1
92
2
93
4
10
501000.0
20
9761000.0
10
502000.0
20
9761000.0
10
502000.0
20
9762000.0
10
501000.0
20
9762000.0
0
ENDSEC
0
EOF
''';
    final doc = parseDxf(hatchDxf);
    final features = buildDxfFeatures(
      doc,
      DxfUtm(zone: 50, southernHemisphere: true),
      [],
    );
    final fills = features['PIT']!
        .where((f) => (f['properties'] as Map)['kind'] == 'fill')
        .toList();
    expect(fills, hasLength(1));
    expect(((fills.single['geometry'] as Map)['coordinates'] as List),
        hasLength(2));
  });

  test('readDxfCache round-trips through the isolate decode', () async {
    final dir = await Directory.systemTemp.createTemp('dxf_cache');
    try {
      final features = {
        'PIT': [_lineFeature(10, '#FF0000')],
      };
      await writeDxfCache(dir, 'test', features);
      final back = await readDxfCache('${dir.path}/dxf/test.json');
      expect(back.keys, {'PIT'});
      expect(
        (back['PIT']!.single['geometry'] as Map)['coordinates'],
        hasLength(10),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('parseDxfFile runs on a background isolate (pickAndParseDxf path)',
      () async {
    final dir = await Directory.systemTemp.createTemp('dxf_compute');
    try {
      final file = File('${dir.path}/t.dxf');
      await file.writeAsString(_dxf);
      final parsed = await compute(parseDxfFile, file.path);
      expect(parsed.doc.entities, isNotEmpty);
      expect(parsed.fileName, 't.dxf');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('parseDxfFile streams large CRLF files identically to parseDxf',
      () async {
    // Larger than the 64 KB read chunk, CRLF line endings, no trailing
    // newline: lines split across chunk boundaries, CR stripping, and
    // the final-line flush must all match the in-memory parser.
    final buf = StringBuffer('0\nSECTION\n2\nENTITIES\n');
    for (var i = 0; i < 3000; i++) {
      buf.write('0\nLINE\n8\nPIT\n10\n${500000 + i}.0\n20\n9760000.0\n'
          '11\n${501000 + i}.0\n21\n9761000.0\n');
    }
    buf.write('0\nTEXT\n8\nLABELS\n10\n500500.0\n20\n9760500.0\n1\nPit é\n'
        '0\nENDSEC\n0\nEOF');
    final content = buf.toString();
    final crlf = content.replaceAll('\n', '\r\n');
    final dir = await Directory.systemTemp.createTemp('dxf_stream');
    try {
      final file = File('${dir.path}/big.dxf');
      await file.writeAsString(crlf);
      expect(await file.length(), greaterThan(64 * 1024));
      final fromFile = await compute(parseDxfFile, file.path);
      final fromString = parseDxf(content);
      expect(fromFile.doc.entities.length, fromString.entities.length);
      expect(fromFile.doc.entities.length, 3001);
      final firstFile = fromFile.doc.entities.first as DxfLine;
      final firstString = fromString.entities.first as DxfLine;
      // DxfPoint has no ==, so compare the coordinates.
      expect(firstFile.a.x, firstString.a.x);
      expect(firstFile.a.y, firstString.a.y);
      expect(firstFile.b.x, firstString.b.x);
      expect(firstFile.b.y, firstString.b.y);
      expect((fromFile.doc.entities.last as DxfText).text,
          (fromString.entities.last as DxfText).text);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('parseDxfFile decodes a multi-byte char split across read chunks',
      () async {
    // 'é' is 2 UTF-8 bytes; place it so its bytes straddle the 64 KB
    // chunk boundary (offset 65535), inside a 65 KB line that spans it.
    const header = '0\nSECTION\n2\nENTITIES\n';
    const textHead = '0\nTEXT\n8\nLABELS\n10\n0.0\n20\n0.0\n1\n';
    final padLen =
        65535 - utf8.encode(header).length - utf8.encode(textHead).length;
    final value = '${'x' * padLen}é';
    final content = '$header$textHead$value\n0\nENDSEC\n0\nEOF\n';
    final dir = await Directory.systemTemp.createTemp('dxf_utf8');
    try {
      final file = File('${dir.path}/u.dxf');
      await file.writeAsString(content);
      final parsed = await compute(parseDxfFile, file.path);
      expect(parsed.doc.entities, hasLength(1));
      expect((parsed.doc.entities.single as DxfText).text, value);
      expect((parseDxf(content).entities.single as DxfText).text, value);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('parseDxfFile tolerates malformed UTF-8 bytes', () async {
    final dir = await Directory.systemTemp.createTemp('dxf_malformed');
    try {
      final bytes = <int>[
        ...ascii.encode('0\nSECTION\n2\nENTITIES\n0\nTEXT\n8\nLABELS\n'
            '10\n500500.0\n20\n9760500.0\n1\nPit '),
        0xFF, // stray non-UTF-8 byte
        ...ascii.encode('\n0\nENDSEC\n0\nEOF\n'),
      ];
      final file = File('${dir.path}/bad.dxf');
      await file.writeAsBytes(bytes);
      final parsed = await compute(parseDxfFile, file.path);
      expect(parsed.doc.entities, hasLength(1));
      expect((parsed.doc.entities.single as DxfText).text, contains('Pit'));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('DxfImport json round-trip', () {
    final imp = DxfImport(
      id: 'abc',
      name: 'Pit design',
      fileName: 'pit.dxf',
      crs: DxfUtm(zone: 50, southernHemisphere: true),
      bounds: [115.0, -2.2, 115.6, -2.1],
      cadLayers: {'PIT': true, 'LABELS': false},
    );
    final back = DxfImport.fromJson(imp.toJson());
    expect(back.id, 'abc');
    expect(back.cadLayers, {'PIT': true, 'LABELS': false});
    expect(back.bounds, [115.0, -2.2, 115.6, -2.1]);
    expect((back.crs as DxfUtm).zone, 50);
  });

  test('progress callback fires', () {
    final doc = parseDxf(_dxf);
    var calls = 0;
    buildDxfFeatures(doc, DxfUtm(zone: 50, southernHemisphere: true), [],
        onProgress: (_, _) => calls++);
    expect(calls, greaterThan(0));
  });

  group('chunkDxfFeatures', () {
    test('small input stays in one chunk', () {
      final byLayer = {
        'PIT': [_lineFeature(10, '#FF0000'), _lineFeature(5, '#00FF00')],
      };
      final chunks = chunkDxfFeatures(byLayer);
      expect(chunks, hasLength(1));
      expect(chunks.single['PIT'], hasLength(2));
    });

    test('splits large input into bounded chunks without losing features',
        () {
      final byLayer = {
        'PIT': [for (var i = 0; i < 20; i++) _lineFeature(500, '#FF0000')],
        'ROADS': [for (var i = 0; i < 20; i++) _lineFeature(500, '#00FF00')],
      };
      final chunks = chunkDxfFeatures(byLayer, maxBytes: 32 * 1024);
      expect(chunks.length, greaterThan(1));
      var total = 0;
      for (final c in chunks) {
        var bytes = 0;
        for (final feats in c.values) {
          for (final f in feats) {
            bytes += estimateFeatureBytes(f);
            total++;
          }
        }
        expect(bytes, lessThanOrEqualTo(32 * 1024 + 24 * 500 + 150));
      }
      expect(total, 40);
    });

    test('a single oversize feature is split across chunks', () {
      final byLayer = {
        'PIT': [_lineFeature(5000, '#FF0000')],
      };
      final chunks = chunkDxfFeatures(byLayer, maxBytes: 16 * 1024);
      expect(chunks.length, greaterThan(1));
      // Reassemble: coordinates in order, no segment lost.
      final coords = <dynamic>[];
      for (final c in chunks) {
        for (final f in c['PIT']!) {
          coords.addAll((f['geometry'] as Map)['coordinates'] as List);
        }
      }
      // Pieces share their boundary point, so dedupe consecutive dups.
      final deduped = <dynamic>[];
      for (final p in coords) {
        if (deduped.isEmpty ||
            deduped.last[0] != p[0] ||
            deduped.last[1] != p[1]) {
          deduped.add(p);
        }
      }
      expect(deduped, hasLength(5000));
      // No chunk exceeds the limit.
      for (final c in chunks) {
        var bytes = 0;
        for (final feats in c.values) {
          for (final f in feats) {
            bytes += estimateFeatureBytes(f);
          }
        }
        expect(bytes, lessThanOrEqualTo(16 * 1024));
      }
    });

    test('estimateFeatureBytes counts coordinate pairs, not numbers', () {
      final f = _lineFeature(100, '#FF0000');
      // 100 pairs at ~24 bytes each + 150 overhead.
      expect(estimateFeatureBytes(f), 24 * 100 + 150);
    });

    test('deterministic chunking', () {
      final byLayer = {
        'B': [for (var i = 0; i < 30; i++) _lineFeature(200, '#FF0000')],
        'A': [for (var i = 0; i < 30; i++) _lineFeature(200, '#00FF00')],
      };
      final a = chunkDxfFeatures(byLayer, maxBytes: 16 * 1024);
      final b = chunkDxfFeatures(byLayer, maxBytes: 16 * 1024);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].keys.toSet(), b[i].keys.toSet());
      }
    });
  });
}
