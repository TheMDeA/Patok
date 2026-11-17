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

  test('NaN and Infinity coordinates fall back instead of poisoning', () {
    final doc = parseDxf(_entities('''
0
LINE
8
PIT
10
NaN
20
5.0
11
1e999
21
7.0
'''));
    final line = doc.entities.whereType<DxfLine>().single;
    expect(line.a.x, 0.0);
    expect(line.a.y, 5.0);
    expect(line.b.x, 0.0);
    expect(line.b.y, 7.0);
  });

  test('TEXT keeps significant spaces; empty values do not shift pairing',
      () {
    final doc = parseDxf(_entities('''
0
TEXT
8
PIT
10
1.0
20
2.0
40
1.0
1
  Bench 12 
0
TEXT
8
PIT
10
3.0
20
4.0
40
1.0
1

0
LINE
8
PIT
10
0.0
20
0.0
11
9.0
21
9.0
'''));
    final texts = doc.entities.whereType<DxfText>().toList();
    expect(texts, hasLength(1)); // the empty-valued one is skipped
    expect(texts.single.text, '  Bench 12 ');
    expect(doc.entities.whereType<DxfLine>(), hasLength(1));
  });

  test('LWPOLYLINE bulge renders as an arc', () {
    final doc = parseDxf(_entities('''
0
LWPOLYLINE
8
PIT
90
2
70
0
10
0.0
20
0.0
42
1.0
10
2.0
20
0.0
'''));
    final pl = doc.entities.whereType<DxfPolyline>().single;
    // Bulge 1 = semicircle: the arc sags to (1, -1).
    expect(pl.vertices.length, greaterThan(2));
    expect(pl.vertices.first.x, 0.0);
    expect(pl.vertices.last.x, closeTo(2.0, 1e-9));
    var minY = 0.0;
    for (final v in pl.vertices) {
      if (v.y < minY) minY = v.y;
    }
    expect(minY, closeTo(-1.0, 0.05));
  });

  test('POLYLINE VERTEX bulge renders as an arc', () {
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
0.0
20
0.0
42
1.0
0
VERTEX
10
2.0
20
0.0
0
SEQEND
'''));
    final pl = doc.entities.whereType<DxfPolyline>().single;
    expect(pl.vertices.length, greaterThan(2));
    var minY = 0.0;
    for (final v in pl.vertices) {
      if (v.y < minY) minY = v.y;
    }
    expect(minY, closeTo(-1.0, 0.05));
  });

  test('SPLINE is approximated by its control polygon', () {
    final doc = parseDxf(_entities('''
0
SPLINE
8
PIT
70
8
10
0.0
20
0.0
10
1.0
20
2.0
10
2.0
20
0.0
'''));
    final pl = doc.entities.whereType<DxfPolyline>().single;
    expect(pl.vertices, hasLength(3));
    expect(pl.vertices[1].x, 1.0);
    expect(pl.vertices[1].y, 2.0);
  });

  test('MTEXT joins continuation groups and strips formatting', () {
    final doc = parseDxf(_entities('''
0
MTEXT
8
PIT
10
1.0
20
2.0
40
1.0
1
{\\FCalibri;Bench
3
 12}\\PSecond line
'''));
    final t = doc.entities.whereType<DxfText>().single;
    expect(t.text, 'Bench 12\nSecond line');
  });

  test('arc bounds use the actual arc, not the full radius box', () {
    final doc = parseDxf(_entities('''
0
ARC
8
0
10
0.0
20
0.0
40
10.0
50
0.0
51
90.0
'''));
    // Quarter arc in the first quadrant only.
    final b = doc.bounds!;
    expect(b[0], closeTo(0.0, 1e-9));
    expect(b[1], closeTo(0.0, 1e-9));
    expect(b[2], closeTo(10.0, 1e-9));
    expect(b[3], closeTo(10.0, 1e-9));
  });

  test('negative ACI color marks the layer off', () {
    final doc = parseDxf('''
$_header
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
HIDDEN
62
-1
0
LAYER
2
SHOWN
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
ENDSEC
0
EOF
''');
    expect(doc.layers['HIDDEN']!.off, isTrue);
    expect(doc.layers['HIDDEN']!.colorIndex, 1);
    expect(doc.layers['SHOWN']!.off, isFalse);
  });

  test('nested INSERT expands and BLOCK base point is honoured', () {
    final doc = parseDxf('''
$_header
0
SECTION
2
BLOCKS
0
BLOCK
2
INNER
10
10.0
20
20.0
0
LINE
8
0
10
0.0
20
0.0
11
5.0
21
0.0
0
ENDBLK
0
BLOCK
2
OUTER
0
INSERT
8
0
2
INNER
10
100.0
20
200.0
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
OUTER
10
1000.0
20
2000.0
0
ENDSEC
0
EOF
''');
    final lines = doc.entities.whereType<DxfLine>().toList();
    expect(lines, hasLength(1));
    // INNER line (0,0)-(5,0), base (10,20): the inner INSERT at (100,200)
    // puts it at (90,180)-(95,180); the outer INSERT at (1000,2000)
    // shifts it to (1090,2180)-(1095,2180).
    expect(lines.single.a.x, closeTo(1090.0, 1e-9));
    expect(lines.single.a.y, closeTo(2180.0, 1e-9));
    expect(lines.single.b.x, closeTo(1095.0, 1e-9));
    expect(lines.single.b.y, closeTo(2180.0, 1e-9));
    expect(lines.single.layer, 'PIT');
  });

  test('cyclic block INSERT does not hang', () {
    final doc = parseDxf('''
$_header
0
SECTION
2
BLOCKS
0
BLOCK
2
LOOP
0
INSERT
8
0
2
LOOP
10
0.0
20
0.0
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
LOOP
10
0.0
20
0.0
0
ENDSEC
0
EOF
''');
    expect(doc.entities.whereType<DxfLine>(), hasLength(1));
  });

  test('non-uniform INSERT scale turns a circle into a polyline', () {
    final doc = parseDxf('''
$_header
0
SECTION
2
BLOCKS
0
BLOCK
2
BLK
0
CIRCLE
8
0
10
0.0
20
0.0
40
2.0
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
BLK
10
10.0
20
20.0
41
2.0
42
1.0
0
ENDSEC
0
EOF
''');
    expect(doc.entities.whereType<DxfCircle>(), isEmpty);
    final pl = doc.entities.whereType<DxfPolyline>().single;
    expect(pl.closed, isTrue);
    // Ellipse: x radius 4, y radius 2, centered at (10, 20).
    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    for (final v in pl.vertices) {
      if (v.x < minX) minX = v.x;
      if (v.x > maxX) maxX = v.x;
      if (v.y < minY) minY = v.y;
      if (v.y > maxY) maxY = v.y;
    }
    expect(minX, closeTo(6.0, 1e-9));
    expect(maxX, closeTo(14.0, 1e-9));
    expect(minY, closeTo(18.0, 1e-9));
    expect(maxY, closeTo(22.0, 1e-9));
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
