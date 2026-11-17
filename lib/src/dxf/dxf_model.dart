/// Data model for a parsed DXF drawing (2D subset used by mine CAD files).
///
/// Z coordinates are flattened: mine plan geometry is drawn in plan view and
/// Patok only needs the XY plane.
library;

import 'dart:math' as math;

/// Segment count for an arc sweeping [sweepDeg] degrees: roughly 10° per
/// segment, so large arcs stay smooth and tiny ones don't waste vertices.
int dxfSegmentsForSweep(double sweepDeg) {
  final n = (sweepDeg.abs() / 10).ceil();
  return n.clamp(4, 96);
}

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
        // Geometric mean of the axis scales: exact for uniform scale, and
        // the area-preserving choice when the insert is stretched.
        height: height * math.sqrt(t.scaleX.abs() * t.scaleY.abs()),
        rotationDeg: rotationDeg + t.rotationDeg,
      );
}

class DxfCircle implements DxfEntity {
  DxfCircle({required this.layer, required this.center, required this.radius});
  @override
  final String layer;
  final DxfPoint center;
  final double radius;

  /// Segmentized ring (closed). Defaults to an adaptive count (~10° per
  /// segment); pass [segments] to override.
  List<DxfPoint> toRing({int? segments}) {
    final n = segments ?? dxfSegmentsForSweep(360);
    return [
      for (var i = 0; i < n; i++)
        DxfPoint(
          center.x + radius * math.cos(2 * math.pi * i / n),
          center.y + radius * math.sin(2 * math.pi * i / n),
        ),
    ];
  }

  @override
  DxfEntity transformed(DxfTransform t) {
    if (t.scaleX == t.scaleY) {
      return DxfCircle(
        layer: layer,
        center: t.apply(center),
        radius: radius * t.scaleX.abs(),
      );
    }
    // Non-uniform scale turns a circle into an ellipse, which has no
    // exact entity here — segmentize it into a polyline instead of
    // distorting it with an averaged radius.
    return DxfPolyline(
      layer: layer,
      vertices: toRing().map(t.apply).toList(),
      closed: true,
    );
  }
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
  /// Defaults to an adaptive count (~10° per segment).
  List<DxfPoint> toPolyline({int? segments}) {
    var sweep = (endDeg - startDeg) % 360;
    if (sweep <= 0) sweep += 360;
    final n = segments ?? dxfSegmentsForSweep(sweep);
    return [
      for (var i = 0; i <= n; i++)
        () {
          final a = (startDeg + sweep * i / n) * math.pi / 180.0;
          return DxfPoint(
            center.x + radius * math.cos(a),
            center.y + radius * math.sin(a),
          );
        }(),
    ];
  }

  @override
  DxfEntity transformed(DxfTransform t) {
    if (t.scaleX == t.scaleY) {
      return DxfArc(
        layer: layer,
        center: t.apply(center),
        radius: radius * t.scaleX.abs(),
        startDeg: startDeg + t.rotationDeg,
        endDeg: endDeg + t.rotationDeg,
      );
    }
    // Non-uniform scale turns an arc into an elliptical arc — segmentize
    // it instead of distorting it with an averaged radius.
    return DxfPolyline(
      layer: layer,
      vertices: toPolyline().map(t.apply).toList(),
      closed: false,
    );
  }
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
  DxfLayer({required this.name, required this.colorIndex, this.off = false});
  final String name;
  final int colorIndex;

  /// True when the layer is turned off in the CAD file (negative ACI color):
  /// its entities are not drawn.
  final bool off;

  /// ARGB color for [colorIndex]; falls back to white for unknown indices.
  int get argb => aciToArgb(colorIndex);
}

/// Point on a circle of radius [r] around [c] at [deg] degrees.
DxfPoint _arcPoint(DxfPoint c, double r, double deg) {
  final a = deg * math.pi / 180.0;
  return DxfPoint(c.x + r * math.cos(a), c.y + r * math.sin(a));
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
        case DxfArc(
            :var center,
            :var radius,
            :var startDeg,
            :var endDeg
          ):
          // Actual arc extrema: the endpoints plus any cardinal point
          // inside the sweep — not the full radius box.
          var sweep = (endDeg - startDeg) % 360;
          if (sweep <= 0) sweep += 360;
          eat(_arcPoint(center, radius, startDeg));
          eat(_arcPoint(center, radius, endDeg));
          for (final a in [0.0, 90.0, 180.0, 270.0]) {
            final rel = (a - startDeg) % 360;
            if (rel > 0 && rel < sweep) eat(_arcPoint(center, radius, a));
          }
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
