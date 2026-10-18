import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/dxf/dxf_crs.dart';
import 'package:patok/src/dxf/dxf_import.dart';
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
