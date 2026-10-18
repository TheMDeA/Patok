import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/dxf/dxf_model.dart';
import 'package:patok/src/dxf/dxf_parser.dart';

const _header = '''
0
SECTION
2
HEADER
0
ENDSEC
''';

const _tables = '''
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
ROADS
62
3
0
ENDTAB
0
ENDSEC
''';

String _entities(String body) => '''
$_header
$_tables
0
SECTION
2
ENTITIES
$body
0
ENDSEC
0
EOF
''';

void main() {
  group('basic entities', () {
    late DxfDocument doc;
    setUp(() {
      doc = parseDxf(_entities('''
0
LINE
8
PIT
10
100.0
20
200.0
11
150.0
21
250.0
0
LWPOLYLINE
8
ROADS
90
3
70
1
10
0.0
20
0.0
10
10.0
20
0.0
10
10.0
20
10.0
0
POINT
8
PIT
10
5.0
20
6.0
0
TEXT
8
PIT
10
7.0
20
8.0
40
2.5
1
Bench 12
0
CIRCLE
8
ROADS
10
20.0
20
20.0
40
5.0
0
ARC
8
PIT
10
30.0
20
30.0
40
4.0
50
0.0
51
90.0
'''));
    });

    test('parses all entity types', () {
      expect(doc.entities.whereType<DxfLine>(), hasLength(1));
      expect(doc.entities.whereType<DxfPolyline>(), hasLength(1));
      expect(doc.entities.whereType<DxfPointEntity>(), hasLength(1));
      expect(doc.entities.whereType<DxfText>(), hasLength(1));
      expect(doc.entities.whereType<DxfCircle>(), hasLength(1));
      expect(doc.entities.whereType<DxfArc>(), hasLength(1));
    });

    test('line coordinates', () {
      final line = doc.entities.whereType<DxfLine>().single;
      expect(line.a.x, 100.0);
      expect(line.a.y, 200.0);
      expect(line.b.x, 150.0);
      expect(line.b.y, 250.0);
      expect(line.layer, 'PIT');
    });

    test('lwpolyline closed flag and vertices', () {
      final pl = doc.entities.whereType<DxfPolyline>().single;
      expect(pl.closed, isTrue);
      expect(pl.vertices, hasLength(3));
      expect(pl.vertices[2].x, 10.0);
      expect(pl.vertices[2].y, 10.0);
    });

    test('text content', () {
      final t = doc.entities.whereType<DxfText>().single;
      expect(t.text, 'Bench 12');
      expect(t.height, 2.5);
    });

    test('arc segmentizes across the sweep', () {
      final arc = doc.entities.whereType<DxfArc>().single;
      final pts = arc.toPolyline(segments: 4);
      expect(pts, hasLength(5));
      // Start at angle 0 -> (34, 30); end at 90 -> (30, 34).
      expect(pts.first.x, closeTo(34.0, 1e-9));
      expect(pts.first.y, closeTo(30.0, 1e-9));
      expect(pts.last.x, closeTo(30.0, 1e-9));
      expect(pts.last.y, closeTo(34.0, 1e-9));
    });

    test('layers carry ACI colors', () {
      expect(doc.layers['PIT']!.colorIndex, 1);
      expect(doc.layers['PIT']!.argb, 0xFFFF0000);
      expect(doc.layers['ROADS']!.colorIndex, 3);
    });
  });

  test('POLYLINE with VERTEX/SEQEND', () {
    final doc = parseDxf(_entities('''
0
POLYLINE
8
PIT
70
0
0
VERTEX
10
1.0
20
2.0
0
VERTEX
10
3.0
20
4.0
0
SEQEND
'''));
    final pl = doc.entities.whereType<DxfPolyline>().single;
    expect(pl.vertices, hasLength(2));
    expect(pl.closed, isFalse);
    expect(pl.vertices[1].x, 3.0);
  });

  test('INSERT expands blocks with transform and BYLAYER', () {
    final doc = parseDxf('''
$_header
0
SECTION
2
BLOCKS
0
BLOCK
2
BOREHOLE
0
CIRCLE
8
0
10
0.0
20
0.0
40
1.0
0
ENDBLK
0
ENDSEC
0
SECTION
2
ENTITIES
0
INSERT
8
PIT
2
BOREHOLE
10
100.0
20
200.0
41
2.0
42
2.0
50
90.0
0
ENDSEC
0
EOF
''');
    final circles = doc.entities.whereType<DxfCircle>();
    expect(circles, hasLength(1));
    final c = circles.single;
    // Scaled by 2, rotated 90deg, translated to (100, 200).
    expect(c.center.x, closeTo(100.0, 1e-9));
    expect(c.center.y, closeTo(200.0, 1e-9));
    expect(c.radius, closeTo(2.0, 1e-9));
    // Block entity was on layer "0" -> inherits INSERT's layer.
    expect(c.layer, 'PIT');
  });

  test('HATCH with line-edge boundary', () {
    final doc = parseDxf(_entities('''
0
HATCH
8
PIT
91
1
93
3
72
1
10
0.0
20
0.0
11
10.0
21
0.0
72
1
10
10.0
20
0.0
11
10.0
21
10.0
72
1
10
10.0
20
10.0
11
0.0
21
0.0
'''));
    final hatch = doc.entities.whereType<DxfHatch>().single;
    expect(hatch.loops, hasLength(1));
    expect(hatch.loops.single.length, greaterThanOrEqualTo(3));
  });

  test('malformed input does not throw', () {
    expect(parseDxf('').entities, isEmpty);
    expect(parseDxf('garbage\nnot dxf\n').entities, isEmpty);
    expect(
        parseDxf(_entities('''
0
LINE
8
PIT
10
not-a-number
20
5.0
''')).entities.whereType<DxfLine>().single.a.x,
        0.0);
  });

  test('bounds cover all geometry', () {
    final doc = parseDxf(_entities('''
0
LINE
8
0
10
-5.0
20
-5.0
11
15.0
21
25.0
0
POINT
8
0
10
100.0
20
-50.0
'''));
    expect(doc.bounds, [-5.0, -50.0, 100.0, 25.0]);
  });

  test('unknown entities are skipped', () {
    final doc = parseDxf(_entities('''
0
SPLINE
8
0
0
LEADER
8
0
0
LINE
8
0
10
0.0
20
0.0
11
1.0
21
1.0
'''));
    expect(doc.entities, hasLength(1));
    expect(doc.entities.single, isA<DxfLine>());
  });
}
