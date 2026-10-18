/// Hand-written ASCII DXF parser (2D subset for mine CAD files).
///
/// Covers the ENTITIES/TABLES/BLOCKS sections and the entity types mines
/// actually use: LINE, LWPOLYLINE, POLYLINE, POINT, TEXT, CIRCLE, ARC,
/// HATCH (line/arc boundaries) and INSERT (expanded via the block table).
/// Z coordinates are flattened. Unknown entities and malformed fields are
/// skipped, never fatal.
library;

import 'dxf_model.dart';

/// One DXF group: a numeric [code] plus its raw string [value].
class _Group {
  _Group(this.code, this.value);
  final int code;
  final String value;
}

/// Parses [content] (ASCII DXF) into a [DxfDocument].
DxfDocument parseDxf(String content) => const _Parser().parse(content);

class _Parser {
  const _Parser();

  DxfDocument parse(String content) {
    final groups = _tokenize(content);
    final layers = <String, DxfLayer>{};
    final blocks = <String, List<DxfEntity>>{};
    final entities = <DxfEntity>[];
    var i = 0;
    while (i < groups.length) {
      final g = groups[i];
      if (g.code == 0 && g.value.toUpperCase() == 'SECTION' && i + 1 < groups.length) {
        final name = groups[i + 1].value.toUpperCase();
        i += 2;
        // Find the matching ENDSEC.
        var end = i;
        while (end < groups.length &&
            !(groups[end].code == 0 && groups[end].value.toUpperCase() == 'ENDSEC')) {
          end++;
        }
        final body = groups.sublist(i, end);
        switch (name) {
          case 'TABLES':
            _parseTables(body, layers);
          case 'BLOCKS':
            _parseBlocks(body, blocks);
          case 'ENTITIES':
            entities.addAll(_parseEntities(body));
        }
        i = end + 1; // skip ENDSEC
      } else {
        i++;
      }
    }
    // Expand INSERTs against the block table.
    final expanded = <DxfEntity>[];
    for (final e in entities) {
      if (e is _DxfInsertRef) {
        expanded.addAll(_expandInsert(e, blocks));
      } else {
        expanded.add(e);
      }
    }
    return DxfDocument(layers: layers, entities: expanded);
  }

  List<_Group> _tokenize(String content) {
    // Blank lines are dropped first so they can never shift the
    // code/value pairing; stray non-numeric lines resync by one.
    final lines = [
      for (final l in content.split('\n')) l.trim(),
    ].where((l) => l.isNotEmpty).toList();
    final out = <_Group>[];
    var i = 0;
    while (i + 1 < lines.length) {
      final code = int.tryParse(lines[i]);
      if (code == null) {
        i++;
        continue;
      }
      out.add(_Group(code, lines[i + 1]));
      i += 2;
    }
    return out;
  }

  // ------------------------------------------------------------ sections

  void _parseTables(List<_Group> body, Map<String, DxfLayer> layers) {
    var i = 0;
    while (i < body.length) {
      final g = body[i];
      if (g.code == 0 && g.value.toUpperCase() == 'LAYER') {
        final slice = _slice(body, i + 1);
        final name = _string(slice, 2, '0');
        final color = _int(slice, 62, 7).abs();
        layers[name] = DxfLayer(name: name, colorIndex: color);
        i += slice.length + 1;
      } else {
        i++;
      }
    }
  }

  void _parseBlocks(List<_Group> body, Map<String, List<DxfEntity>> blocks) {
    var i = 0;
    while (i < body.length) {
      final g = body[i];
      if (g.code == 0 && g.value.toUpperCase() == 'BLOCK') {
        final head = _slice(body, i + 1);
        final name = _string(head, 2, '');
        i += head.length + 1;
        // Entities until ENDBLK.
        var end = i;
        while (end < body.length &&
            !(body[end].code == 0 && body[end].value.toUpperCase() == 'ENDBLK')) {
          end++;
        }
        blocks[name] = _parseEntities(body.sublist(i, end));
        i = end + 1;
      } else {
        i++;
      }
    }
  }

  List<DxfEntity> _parseEntities(List<_Group> body) {
    final out = <DxfEntity>[];
    var i = 0;
    while (i < body.length) {
      final g = body[i];
      if (g.code != 0) {
        i++;
        continue;
      }
      final type = g.value.toUpperCase();
      final slice = _slice(body, i + 1);
      final entity = _parseEntity(type, slice, body, i + 1 + slice.length);
      if (entity != null) out.add(entity);
      i += slice.length + 1;
      // POLYLINE consumes its VERTEX children + SEQEND.
      if (type == 'POLYLINE') {
        final extra = _parsePolylineVertices(body, i);
        (out.last as DxfPolyline)
            .vertices
            .addAll(extra.$1.map((v) => DxfPoint(v.$1, v.$2)));
        i = extra.$2;
      }
    }
    return out;
  }

  /// Parses VERTEX entities following a POLYLINE header. Returns the
  /// (x, y) pairs plus the index just past SEQEND.
  (List<(double, double)>, int) _parsePolylineVertices(
      List<_Group> body, int start) {
    final verts = <(double, double)>[];
    var i = start;
    while (i < body.length) {
      final g = body[i];
      if (g.code == 0) {
        final type = g.value.toUpperCase();
        if (type == 'SEQEND') {
          return (verts, i + 1 + _slice(body, i + 1).length);
        }
        if (type == 'VERTEX') {
          final slice = _slice(body, i + 1);
          verts.add((_double(slice, 10, 0), _double(slice, 20, 0)));
          i += slice.length + 1;
          continue;
        }
        return (verts, i); // unexpected: stop
      }
      i++;
    }
    return (verts, i);
  }

  /// Groups belonging to one object: pairs until the next code-0.
  List<_Group> _slice(List<_Group> body, int start) {
    var end = start;
    while (end < body.length && body[end].code != 0) {
      end++;
    }
    return body.sublist(start, end);
  }

  // ------------------------------------------------------------ entities

  DxfEntity? _parseEntity(
      String type, List<_Group> s, List<_Group> body, int after) {
    switch (type) {
      case 'LINE':
        return DxfLine(
          layer: _layer(s),
          a: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          b: DxfPoint(_double(s, 11, 0), _double(s, 21, 0)),
        );
      case 'LWPOLYLINE':
        final verts = <DxfPoint>[];
        for (var k = 0; k < s.length; k++) {
          if (s[k].code == 10 && k + 1 < s.length && s[k + 1].code == 20) {
            verts.add(DxfPoint(
              _parseDouble(s[k].value, 0),
              _parseDouble(s[k + 1].value, 0),
            ));
          }
        }
        return DxfPolyline(
          layer: _layer(s),
          vertices: verts,
          closed: (_int(s, 70, 0) & 1) != 0,
        );
      case 'POLYLINE':
        // Vertices are consumed by the caller.
        return DxfPolyline(
          layer: _layer(s),
          vertices: [],
          closed: (_int(s, 70, 0) & 1) != 0,
        );
      case 'POINT':
        return DxfPointEntity(
          layer: _layer(s),
          position: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
        );
      case 'TEXT':
      case 'MTEXT':
        final text = _string(s, 1, '');
        if (text.isEmpty) return null;
        return DxfText(
          layer: _layer(s),
          position: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          text: text,
          height: _double(s, 40, 1),
          rotationDeg: _double(s, 50, 0),
        );
      case 'CIRCLE':
        return DxfCircle(
          layer: _layer(s),
          center: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          radius: _double(s, 40, 0),
        );
      case 'ARC':
        return DxfArc(
          layer: _layer(s),
          center: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          radius: _double(s, 40, 0),
          startDeg: _double(s, 50, 0),
          endDeg: _double(s, 51, 360),
        );
      case 'HATCH':
        return _parseHatch(s, _layer(s));
      case 'INSERT':
        return _DxfInsertRef(
          layer: _layer(s),
          blockName: _string(s, 2, ''),
          position: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          scaleX: _double(s, 41, 1),
          scaleY: _double(s, 42, 1),
          rotationDeg: _double(s, 50, 0),
        );
      default:
        return null; // unsupported entity: skip
    }
  }

  DxfEntity? _parseHatch(List<_Group> s, String layer) {
    final loops = <List<DxfPoint>>[];
    var k = 0;
    var polylinePath = false;
    while (k < s.length) {
      final g = s[k];
      if (g.code == 92) {
        // Boundary path type flag: bit 2 = polyline path.
        polylinePath = ((int.tryParse(g.value) ?? 0) & 2) != 0;
        k++;
      } else if (g.code == 93) {
        final n = int.tryParse(g.value) ?? 0;
        k++;
        if (polylinePath) {
          final loop = <DxfPoint>[];
          var read = 0;
          while (k + 1 < s.length && read < n) {
            if (s[k].code == 10 && s[k + 1].code == 20) {
              loop.add(DxfPoint(
                _parseDouble(s[k].value, 0),
                _parseDouble(s[k + 1].value, 0),
              ));
              read++;
              k += 2;
            } else {
              k++;
            }
          }
          if (loop.length >= 3) loops.add(loop);
        } else {
          // Edge-based path: 72 selects the edge type.
          final loop = <DxfPoint>[];
          var edges = 0;
          while (k < s.length && edges < n) {
            if (s[k].code == 72) {
              final edgeType = int.tryParse(s[k].value) ?? 0;
              if (edgeType == 1) {
                final seg = _edgeLine(s, k);
                if (seg != null) {
                  if (loop.isEmpty) loop.add(seg.$1);
                  loop.add(seg.$2);
                }
                k = seg?.$3 ?? (k + 1);
              } else if (edgeType == 2) {
                final seg = _edgeArc(s, k);
                if (seg != null) loop.addAll(seg.$1);
                k = seg?.$2 ?? (k + 1);
              } else {
                k++; // elliptic arc / spline: skip
              }
              edges++;
            } else {
              k++;
            }
          }
          if (loop.length >= 3) loops.add(loop);
        }
      } else {
        k++;
      }
    }
    if (loops.isEmpty) return null;
    return DxfHatch(layer: layer, loops: loops);
  }

  (DxfPoint, DxfPoint, int)? _edgeLine(List<_Group> s, int start) {
    double? x1, y1, x2, y2;
    var k = start + 1;
    while (k < s.length && (s[k].code == 10 || s[k].code == 20 || s[k].code == 11 || s[k].code == 21)) {
      switch (s[k].code) {
        case 10:
          x1 = _parseDouble(s[k].value, 0);
        case 20:
          y1 = _parseDouble(s[k].value, 0);
        case 11:
          x2 = _parseDouble(s[k].value, 0);
        case 21:
          y2 = _parseDouble(s[k].value, 0);
      }
      k++;
    }
    if (x1 == null || y1 == null || x2 == null || y2 == null) return null;
    return (DxfPoint(x1, y1), DxfPoint(x2, y2), k);
  }

  (List<DxfPoint>, int)? _edgeArc(List<_Group> s, int start) {
    double cx = 0, cy = 0, r = 0, a0 = 0, a1 = 360;
    var k = start + 1;
    while (k < s.length &&
        (s[k].code == 10 || s[k].code == 20 || s[k].code == 40 || s[k].code == 50 || s[k].code == 51)) {
      switch (s[k].code) {
        case 10:
          cx = _parseDouble(s[k].value, 0);
        case 20:
          cy = _parseDouble(s[k].value, 0);
        case 40:
          r = _parseDouble(s[k].value, 0);
        case 50:
          a0 = _parseDouble(s[k].value, 0);
        case 51:
          a1 = _parseDouble(s[k].value, 360);
      }
      k++;
    }
    if (r <= 0) return null;
    return (
      DxfArc(
              layer: '',
              center: DxfPoint(cx, cy),
              radius: r,
              startDeg: a0,
              endDeg: a1)
          .toPolyline(),
      k
    );
  }

  List<DxfEntity> _expandInsert(
      _DxfInsertRef ins, Map<String, List<DxfEntity>> blocks) {
    final def = blocks[ins.blockName];
    if (def == null || def.isEmpty) return const [];
    final t = DxfTransform(
      dx: ins.position.x,
      dy: ins.position.y,
      scaleX: ins.scaleX,
      scaleY: ins.scaleY,
      rotationDeg: ins.rotationDeg,
    );
    return [
      for (final e in def)
        // BYLAYER: entities on layer "0" inherit the INSERT's layer.
        (e.layer == '0' ? _reLayer(e, ins.layer) : e).transformed(t),
    ];
  }

  DxfEntity _reLayer(DxfEntity e, String layer) {
    // Rebuild the entity on [layer] (only used for block contents).
    switch (e) {
      case DxfLine(:var a, :var b):
        return DxfLine(layer: layer, a: a, b: b);
      case DxfPolyline(:var vertices, :var closed):
        return DxfPolyline(layer: layer, vertices: vertices, closed: closed);
      case DxfPointEntity(:var position):
        return DxfPointEntity(layer: layer, position: position);
      case DxfText(:var position, :var text, :var height, :var rotationDeg):
        return DxfText(
            layer: layer,
            position: position,
            text: text,
            height: height,
            rotationDeg: rotationDeg);
      case DxfCircle(:var center, :var radius):
        return DxfCircle(layer: layer, center: center, radius: radius);
      case DxfArc(
          :var center,
          :var radius,
          :var startDeg,
          :var endDeg
        ):
        return DxfArc(
            layer: layer,
            center: center,
            radius: radius,
            startDeg: startDeg,
            endDeg: endDeg);
      case DxfHatch(:var loops):
        return DxfHatch(layer: layer, loops: loops);
      default:
        return e;
    }
  }

  // ------------------------------------------------------------ helpers

  String _layer(List<_Group> s) => _string(s, 8, '0');

  String _string(List<_Group> s, int code, String fallback) {
    for (final g in s) {
      if (g.code == code) return g.value;
    }
    return fallback;
  }

  double _double(List<_Group> s, int code, double fallback) {
    for (final g in s) {
      if (g.code == code) return _parseDouble(g.value, fallback);
    }
    return fallback;
  }

  int _int(List<_Group> s, int code, int fallback) {
    for (final g in s) {
      if (g.code == code) return int.tryParse(g.value) ?? fallback;
    }
    return fallback;
  }

  double _parseDouble(String v, double fallback) =>
      double.tryParse(v.trim()) ?? fallback;
}

/// Internal INSERT reference, expanded after the full parse.
class _DxfInsertRef implements DxfEntity {
  _DxfInsertRef({
    required this.layer,
    required this.blockName,
    required this.position,
    required this.scaleX,
    required this.scaleY,
    required this.rotationDeg,
  });
  @override
  final String layer;
  final String blockName;
  final DxfPoint position;
  final double scaleX;
  final double scaleY;
  final double rotationDeg;

  @override
  DxfEntity transformed(DxfTransform t) => this; // never called
}
