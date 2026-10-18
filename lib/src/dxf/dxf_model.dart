/// Data model for a parsed DXF drawing (2D subset used by mine CAD files).
///
/// Z coordinates are flattened: mine plan geometry is drawn in plan view and
/// Patok only needs the XY plane.
library;

import 'dart:math' as math;

/// A 2D point in the drawing's native coordinates (easting/northing).
class DxfPoint {
  const DxfPoint(this.x, this.y);
  final double x;
  final double y;

  @override
  String toString() => '($x, $y)';
}

/// Rigid transform (translate + rotate + non-uniform scale) used to expand
/// block INSERTs into concrete entities.
class DxfTransform {
  const DxfTransform({
    this.dx = 0,
    this.dy = 0,
    this.scaleX = 1,
    this.scaleY = 1,
    this.rotationDeg = 0,
  });

  final double dx;
  final double dy;
  final double scaleX;
  final double scaleY;
  final double rotationDeg;

  DxfPoint apply(DxfPoint p) {
    final rad = rotationDeg * math.pi / 180.0;
    final cosR = math.cos(rad);
    final sinR = math.sin(rad);
    final sx = p.x * scaleX;
    final sy = p.y * scaleY;
    return DxfPoint(
      dx + sx * cosR - sy * sinR,
      dy + sx * sinR + sy * cosR,
    );
  }
}

/// Base class for all parsed entities. Every entity knows its DXF layer.
abstract class DxfEntity {
  String get layer;

  /// Returns a copy with [t] applied (used for INSERT expansion).
  DxfEntity transformed(DxfTransform t);
}

class DxfLine implements DxfEntity {
  DxfLine({required this.layer, required this.a, required this.b});
  @override
  final String layer;
  final DxfPoint a;
  final DxfPoint b;

  @override
  DxfLine transformed(DxfTransform t) =>
      DxfLine(layer: layer, a: t.apply(a), b: t.apply(b));
}

class DxfPolyline implements DxfEntity {
  DxfPolyline({
    required this.layer,
    required this.vertices,
    required this.closed,
  });
  @override
  final String layer;
  final List<DxfPoint> vertices;
  final bool closed;

  @override
  DxfPolyline transformed(DxfTransform t) => DxfPolyline(
        layer: layer,
        vertices: vertices.map(t.apply).toList(),
        closed: closed,
      );
}

class DxfPointEntity implements DxfEntity {
  DxfPointEntity({required this.layer, required this.position});
  @override
  final String layer;
  final DxfPoint position;

  @override
  DxfPointEntity transformed(DxfTransform t) =>
      DxfPointEntity(layer: layer, position: t.apply(position));
}

class DxfText implements DxfEntity {
  DxfText({
    required this.layer,
    required this.position,
    required this.text,
    required this.height,
    required this.rotationDeg,
  });
  @override
  final String layer;
  final DxfPoint position;
  final String text;
  final double height;
  final double rotationDeg;

  @override
  DxfText transformed(DxfTransform t) => DxfText(
        layer: layer,
        position: t.apply(position),
        text: text,
        height: height * (t.scaleX.abs() + t.scaleY.abs()) / 2,
        rotationDeg: rotationDeg + t.rotationDeg,
      );
}

class DxfCircle implements DxfEntity {
  DxfCircle({required this.layer, required this.center, required this.radius});
  @override
  final String layer;
  final DxfPoint center;
  final double radius;

  /// Segmentized ring (closed).
  List<DxfPoint> toRing({int segments = 48}) => [
        for (var i = 0; i < segments; i++)
          DxfPoint(
            center.x + radius * math.cos(2 * math.pi * i / segments),
            center.y + radius * math.sin(2 * math.pi * i / segments),
          ),
      ];

  @override
  DxfCircle transformed(DxfTransform t) => DxfCircle(
        layer: layer,
        center: t.apply(center),
        radius: radius * (t.scaleX.abs() + t.scaleY.abs()) / 2,
      );
}

class DxfArc implements DxfEntity {
  DxfArc({
    required this.layer,
    required this.center,
    required this.radius,
    required this.startDeg,
    required this.endDeg,
  });
  @override
  final String layer;
  final DxfPoint center;
  final double radius;
  final double startDeg;
  final double endDeg;

  /// Segmentized polyline from [startDeg] to [endDeg] (counter-clockwise).
  List<DxfPoint> toPolyline({int segments = 24}) {
    var sweep = (endDeg - startDeg) % 360;
    if (sweep <= 0) sweep += 360;
    return [
      for (var i = 0; i <= segments; i++)
        () {
          final a = (startDeg + sweep * i / segments) * math.pi / 180.0;
          return DxfPoint(
            center.x + radius * math.cos(a),
            center.y + radius * math.sin(a),
          );
        }(),
    ];
  }

  @override
  DxfArc transformed(DxfTransform t) => DxfArc(
        layer: layer,
        center: t.apply(center),
        radius: radius * (t.scaleX.abs() + t.scaleY.abs()) / 2,
        startDeg: startDeg + t.rotationDeg,
        endDeg: endDeg + t.rotationDeg,
      );
}

/// A HATCH boundary loop set (each loop = closed ring of points).
class DxfHatch implements DxfEntity {
  DxfHatch({required this.layer, required this.loops});
  @override
  final String layer;
  final List<List<DxfPoint>> loops;

  @override
  DxfHatch transformed(DxfTransform t) => DxfHatch(
        layer: layer,
        loops: loops
            .map((loop) => loop.map(t.apply).toList())
            .toList(),
      );
}

/// A named layer with its AutoCAD color index (1-255).
class DxfLayer {
  DxfLayer({required this.name, required this.colorIndex});
  final String name;
  final int colorIndex;

  /// ARGB color for [colorIndex]; falls back to white for unknown indices.
  int get argb => aciToArgb(colorIndex);
}

/// A fully parsed drawing: layers plus entities with block INSERTs expanded.
class DxfDocument {
  DxfDocument({required this.layers, required this.entities});
  final Map<String, DxfLayer> layers;
  final List<DxfEntity> entities;

  /// (minX, minY, maxX, maxY) over all entity geometry, or null when empty.
  List<double>? get bounds {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    void eat(DxfPoint p) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }

    for (final e in entities) {
      switch (e) {
        case DxfLine(:var a, :var b):
          eat(a);
          eat(b);
        case DxfPolyline(:var vertices):
          for (final v in vertices) {
            eat(v);
          }
        case DxfPointEntity(:var position):
          eat(position);
        case DxfText(:var position):
          eat(position);
        case DxfCircle(:var center, :var radius):
          eat(DxfPoint(center.x - radius, center.y - radius));
          eat(DxfPoint(center.x + radius, center.y + radius));
        case DxfArc(:var center, :var radius):
          eat(DxfPoint(center.x - radius, center.y - radius));
          eat(DxfPoint(center.x + radius, center.y + radius));
        case DxfHatch(:var loops):
          for (final loop in loops) {
            for (final v in loop) {
              eat(v);
            }
          }
      }
    }
    if (minX == double.infinity) return null;
    return [minX, minY, maxX, maxY];
  }
}

// Set by dxf_parser.dart's palette loader; defaults cover ACI 1-9.
int Function(int) aciToArgb = _fallbackAciToArgb;

int _fallbackAciToArgb(int index) {
  const base = {
    1: 0xFFFF0000, // red
    2: 0xFFFFFF00, // yellow
    3: 0xFF00FF00, // green
    4: 0xFF00FFFF, // cyan
    5: 0xFF0000FF, // blue
    6: 0xFFFF00FF, // magenta
    7: 0xFFFFFFFF, // white
    8: 0xFF808080, // dark gray
    9: 0xFFC0C0C0, // light gray
  };
  return base[index] ?? 0xFFFFFFFF;
}
