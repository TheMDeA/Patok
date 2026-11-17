/// Hand-written ASCII DXF parser (2D subset for mine CAD files).
///
/// Covers the ENTITIES/TABLES/BLOCKS sections and the entity types mines
/// actually use: LINE, LWPOLYLINE, POLYLINE, POINT, TEXT, CIRCLE, ARC,
/// HATCH (line/arc boundaries) and INSERT (expanded via the block table,
/// including nested INSERTs and BLOCK base points). Bulge arcs on
/// polylines are segmentized; SPLINE is approximated by its control
/// polygon. Z coordinates are flattened. Unknown entities and malformed
/// fields are skipped, never fatal.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'dxf_model.dart';

/// One DXF group: a numeric [code] plus its raw string [value].
class _Group {
  _Group(this.code, this.value);
  final int code;
  final String value;
}

/// Parses [content] (ASCII DXF) into a [DxfDocument].
///
/// The parse streams: lines are produced lazily from the string, paired
/// into groups lazily, and consumed by a cursor — the whole file is never
/// held as a lines list, a groups list, or section copies. For files on
/// disk prefer [parseDxfLines] with [dxfFileLines], which also avoids
/// loading the file into a string at all.
DxfDocument parseDxf(String content) =>
    const _Parser().parse(_linesOf(content));

/// Parses a DXF from lazily-produced [lines] (split on '\n', '\r' kept
/// for the tokenizer to strip).
DxfDocument parseDxfLines(Iterable<String> lines) =>
    const _Parser().parse(lines);

/// Lazily splits [content] into lines with the same results as
/// `content.split('\n')` (including the trailing empty line), without
/// building a lines list.
Iterable<String> _linesOf(String content) sync* {
  var start = 0;
  while (true) {
    final nl = content.indexOf('\n', start);
    if (nl < 0) {
      yield content.substring(start);
      return;
    }
    yield content.substring(start, nl);
    start = nl + 1;
    if (start == content.length) {
      yield ''; // trailing newline: split() yields a final empty line
      return;
    }
  }
}

/// Lazily reads [file] as lines (split on '\n', '\r' kept) without
/// loading the file into memory: 64 KB chunks, decoded incrementally.
/// Malformed bytes become U+FFFD, matching the old
/// `utf8.decode(bytes, allowMalformed: true)`.
Iterable<String> dxfFileLines(File file) sync* {
  final raf = file.openSync(mode: FileMode.read);
  try {
    final decoded = <String>[];
    final sink = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_CollectSink(decoded));
    final lines = _LineBuffer();
    while (true) {
      final chunk = raf.readSync(64 * 1024);
      if (chunk.isEmpty) break;
      sink.add(chunk);
      for (final text in decoded) {
        yield* lines.add(text);
      }
      decoded.clear();
    }
    sink.close();
    for (final text in decoded) {
      yield* lines.add(text);
    }
    decoded.clear();
    // The final line (no trailing newline), or '' when the file ends
    // with a newline — matching split() in both cases.
    yield lines.flush();
  } finally {
    raf.closeSync();
  }
}

/// Accumulates decoded text into complete lines; the tail (no trailing
/// newline yet) stays buffered.
class _LineBuffer {
  final _partial = StringBuffer();

  /// Splits [text] into its complete lines; the tail stays buffered.
  List<String> add(String text) {
    final out = <String>[];
    var start = 0;
    while (true) {
      final nl = text.indexOf('\n', start);
      if (nl < 0) {
        _partial.write(text.substring(start));
        return out;
      }
      _partial.write(text.substring(start, nl));
      out.add(_partial.toString());
      _partial.clear();
      start = nl + 1;
    }
  }

  /// The buffered tail as the final line ('' when the input ended with
  /// a newline).
  String flush() => _partial.toString();
}

/// Forwards decoded strings into a list, for the chunked UTF-8 decoder.
class _CollectSink implements Sink<String> {
  _CollectSink(this.out);
  final List<String> out;

  @override
  void add(String data) => out.add(data);

  @override
  void close() {}
}

/// Pull-based cursor over lazily-produced groups, with a one-group
/// lookahead. The parser never holds more than the peeked group plus
/// the current entity's slice.
class _GroupCursor {
  _GroupCursor(this._it);
  final Iterator<_Group> _it;
  _Group? _peeked;
  bool _hasPeeked = false;

  _Group? peek() {
    if (!_hasPeeked) {
      _hasPeeked = _it.moveNext();
      if (_hasPeeked) _peeked = _it.current;
    }
    return _peeked;
  }

  _Group? next() {
    final g = peek();
    _peeked = null;
    _hasPeeked = false;
    return g;
  }
}

class _Parser {
  const _Parser();

  DxfDocument parse(Iterable<String> lines) {
    final groups = _GroupCursor(_tokenize(lines.iterator).iterator);
    final layers = <String, DxfLayer>{};
    final blocks = <String, _BlockDef>{};
    final entities = <DxfEntity>[];
    while (true) {
      final g = groups.next();
      if (g == null) break;
      if (g.code == 0 && g.value.toUpperCase() == 'SECTION') {
        final nameGroup = groups.next();
        if (nameGroup == null) break;
        switch (nameGroup.value.toUpperCase()) {
          case 'TABLES':
            _parseTables(groups, layers);
          case 'BLOCKS':
            _parseBlocks(groups, blocks);
          case 'ENTITIES':
            entities.addAll(_parseEntities(groups, 'ENDSEC'));
          default:
            _skipSection(groups);
        }
      }
      // Any other group outside a section is skipped.
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

  /// Pairs consecutive lines into (code, value) groups, lazily: an empty
  /// line can be a legitimate (empty) value, and TEXT values may carry
  /// significant leading/trailing spaces — dropping or trimming either
  /// would shift the code/value pairing. Only a trailing CR (CRLF files)
  /// is stripped. Stray non-numeric lines resync by one.
  Iterable<_Group> _tokenize(Iterator<String> lines) sync* {
    while (true) {
      if (!lines.moveNext()) return;
      final code = int.tryParse(lines.current);
      if (code == null) continue;
      if (!lines.moveNext()) return;
      var value = lines.current;
      if (value.endsWith('\r')) {
        value = value.substring(0, value.length - 1);
      }
      yield _Group(code, value);
    }
  }

  /// Consumes groups up to and including the section's ENDSEC (or EOF).
  void _skipSection(_GroupCursor groups) {
    while (true) {
      final g = groups.next();
      if (g == null) return;
      if (g.code == 0 && g.value.toUpperCase() == 'ENDSEC') return;
    }
  }

  // ------------------------------------------------------------ sections

  void _parseTables(_GroupCursor groups, Map<String, DxfLayer> layers) {
    while (true) {
      final g = groups.peek();
      if (g == null) return;
      if (g.code == 0 && g.value.toUpperCase() == 'ENDSEC') {
        groups.next();
        return;
      }
      if (g.code == 0 && g.value.toUpperCase() == 'LAYER') {
        groups.next(); // consume the LAYER header
        final slice = _collectUntilCode0(groups);
        final name = _string(slice, 2, '0');
        // A negative ACI color means the layer is turned off in CAD;
        // keep the sign instead of discarding it with .abs().
        final rawColor = _int(slice, 62, 7);
        layers[name] = DxfLayer(
          name: name,
          colorIndex: rawColor.abs(),
          off: rawColor < 0,
        );
      } else {
        groups.next(); // TABLE, ENDTAB, stray groups: skip
      }
    }
  }

  void _parseBlocks(_GroupCursor groups, Map<String, _BlockDef> blocks) {
    while (true) {
      final g = groups.peek();
      if (g == null) return;
      if (g.code == 0 && g.value.toUpperCase() == 'ENDSEC') {
        groups.next();
        return;
      }
      if (g.code == 0 && g.value.toUpperCase() == 'BLOCK') {
        groups.next(); // consume the BLOCK header
        final head = _collectUntilCode0(groups);
        final name = _string(head, 2, '');
        // BLOCK base point (codes 10/20): block entities are relative
        // to it, and INSERT expansion must subtract it first.
        final base = DxfPoint(_double(head, 10, 0), _double(head, 20, 0));
        blocks[name] = _BlockDef(base, _parseEntities(groups, 'ENDBLK'));
      } else {
        groups.next();
      }
    }
  }

  /// Parses entities until the [terminator] group ('ENDSEC' for the
  /// ENTITIES section, 'ENDBLK' inside a BLOCK), consuming it.
  List<DxfEntity> _parseEntities(_GroupCursor groups, String terminator) {
    final out = <DxfEntity>[];
    while (true) {
      final g = groups.peek();
      if (g == null) return out;
      if (g.code == 0 && g.value.toUpperCase() == terminator) {
        groups.next(); // consume the terminator
        return out;
      }
      if (g.code != 0) {
        groups.next(); // stray group: skip
        continue;
      }
      final type = g.value.toUpperCase();
      groups.next(); // consume the code-0 header
      final slice = _collectUntilCode0(groups);
      final entity = _parseEntity(type, slice);
      if (entity != null) out.add(entity);
      // POLYLINE consumes its VERTEX children + SEQEND.
      if (type == 'POLYLINE') {
        final verts = _parsePolylineVertices(groups);
        final pl = out.last as DxfPolyline;
        pl.vertices.addAll(_expandBulges(verts, pl.closed));
      }
    }
  }

  /// Parses VERTEX entities following a POLYLINE header, consuming up to
  /// and including SEQEND (plus its fields). An unexpected code-0 group
  /// stops the scan without consuming it, so the caller sees it next.
  List<(DxfPoint, double)> _parsePolylineVertices(_GroupCursor groups) {
    final verts = <(DxfPoint, double)>[];
    while (true) {
      final g = groups.peek();
      if (g == null) return verts;
      if (g.code == 0) {
        final type = g.value.toUpperCase();
        if (type == 'SEQEND') {
          groups.next(); // consume SEQEND
          _collectUntilCode0(groups); // discard its fields
          return verts;
        }
        if (type == 'VERTEX') {
          groups.next(); // consume VERTEX
          final slice = _collectUntilCode0(groups);
          verts.add((
            DxfPoint(_double(slice, 10, 0), _double(slice, 20, 0)),
            _double(slice, 42, 0),
          ));
          continue;
        }
        return verts; // unexpected: stop, leave the group for the caller
      }
      groups.next(); // stray non-zero group: skip
    }
  }

  /// Groups until the next code-0 group (left for the caller) or end of
  /// input. Replaces the old `_slice`, which copied a window out of a
  /// materialized groups list.
  List<_Group> _collectUntilCode0(_GroupCursor groups) {
    final out = <_Group>[];
    while (true) {
      final g = groups.peek();
      if (g == null || g.code == 0) return out;
      out.add(groups.next()!);
    }
  }

  // ------------------------------------------------------------ entities

  DxfEntity? _parseEntity(String type, List<_Group> s) {
    switch (type) {
      case 'LINE':
        return DxfLine(
          layer: _layer(s),
          a: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          b: DxfPoint(_double(s, 11, 0), _double(s, 21, 0)),
        );
      case 'LWPOLYLINE':
        final raw = <(DxfPoint, double)>[];
        for (var k = 0; k < s.length; k++) {
          if (s[k].code == 10 && k + 1 < s.length && s[k + 1].code == 20) {
            // Code 42 on this vertex is the bulge of the arc to the
            // next vertex (tan of a quarter of the included angle).
            var bulge = 0.0;
            for (var j = k + 2; j < s.length && s[j].code != 10; j++) {
              if (s[j].code == 42) bulge = _parseDouble(s[j].value, 0);
            }
            raw.add((
              DxfPoint(
                _parseDouble(s[k].value, 0),
                _parseDouble(s[k + 1].value, 0),
              ),
              bulge,
            ));
          }
        }
        final closed = (_int(s, 70, 0) & 1) != 0;
        return DxfPolyline(
          layer: _layer(s),
          vertices: _expandBulges(raw, closed),
          closed: closed,
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
        final text = _string(s, 1, '');
        if (text.isEmpty) return null;
        return DxfText(
          layer: _layer(s),
          position: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          text: text,
          height: _double(s, 40, 1),
          rotationDeg: _double(s, 50, 0),
        );
      case 'MTEXT':
        // Text continues in code-3 groups after the first code-1 group.
        final raw = _string(s, 1, '') +
            s.where((g) => g.code == 3).map((g) => g.value).join();
        final mtext = _cleanMText(raw);
        if (mtext.isEmpty) return null;
        return DxfText(
          layer: _layer(s),
          position: DxfPoint(_double(s, 10, 0), _double(s, 20, 0)),
          text: mtext,
          height: _double(s, 40, 1),
          rotationDeg: _double(s, 50, 0),
        );
      case 'SPLINE':
        // Approximated by its control polygon: a true NURBS fit is out
        // of scope, but the control points trace the curve's shape.
        final pts = <DxfPoint>[];
        for (var k = 0; k < s.length; k++) {
          if (s[k].code == 10 && k + 1 < s.length && s[k + 1].code == 20) {
            pts.add(DxfPoint(
              _parseDouble(s[k].value, 0),
              _parseDouble(s[k + 1].value, 0),
            ));
          }
        }
        if (pts.length < 2) return null;
        return DxfPolyline(layer: _layer(s), vertices: pts, closed: false);
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
    _DxfInsertRef ins,
    Map<String, _BlockDef> blocks, [
    Set<String>? expanding,
    _Affine? outer,
  ]) {
    final def = blocks[ins.blockName];
    if (def == null || def.entities.isEmpty) return const [];
    expanding ??= {};
    // A block that inserts itself (directly or through others) would
    // recurse forever — drop the cyclic branch.
    if (expanding.contains(ins.blockName)) return const [];
    // insert + R*S*(entity - base), composed with the outer transform
    // when this INSERT lives inside another block.
    final inner = _Affine.fromInsert(ins, def.base);
    final aff = outer == null ? inner : outer.compose(inner);
    final next = {...expanding, ins.blockName};
    final out = <DxfEntity>[];
    for (final e in def.entities) {
      // BYLAYER: entities on layer "0" inherit the INSERT's layer.
      final entity = e.layer == '0' ? _reLayer(e, ins.layer) : e;
      if (entity is _DxfInsertRef) {
        out.addAll(_expandInsert(entity, blocks, next, aff));
      } else {
        out.add(_applyAffine(entity, aff));
      }
    }
    return out;
  }

  /// Applies a general affine transform to an entity. When the transform
  /// is a rotation times (possibly non-uniform) scale it goes through
  /// [DxfEntity.transformed]; a sheared transform maps points directly
  /// (circles/arcs become polylines — an ellipse has no exact entity).
  DxfEntity _applyAffine(DxfEntity e, _Affine aff) {
    final t = aff.toDxfTransform();
    if (t != null) return e.transformed(t);
    switch (e) {
      case DxfLine(:var a, :var b):
        return DxfLine(layer: e.layer, a: aff.apply(a), b: aff.apply(b));
      case DxfPolyline(:var vertices, :var closed):
        return DxfPolyline(
          layer: e.layer,
          vertices: vertices.map(aff.apply).toList(),
          closed: closed,
        );
      case DxfPointEntity(:var position):
        return DxfPointEntity(layer: e.layer, position: aff.apply(position));
      case DxfText(:var position, :var text, :var height, :var rotationDeg):
        final det = (aff.a * aff.d - aff.b * aff.c).abs();
        return DxfText(
          layer: e.layer,
          position: aff.apply(position),
          text: text,
          height: height * math.sqrt(det),
          rotationDeg:
              rotationDeg + math.atan2(aff.c, aff.a) * 180 / math.pi,
        );
      case DxfCircle():
        return DxfPolyline(
          layer: e.layer,
          vertices: e.toRing().map(aff.apply).toList(),
          closed: true,
        );
      case DxfArc():
        return DxfPolyline(
          layer: e.layer,
          vertices: e.toPolyline().map(aff.apply).toList(),
          closed: false,
        );
      case DxfHatch(:var loops):
        return DxfHatch(
          layer: e.layer,
          loops: loops.map((l) => l.map(aff.apply).toList()).toList(),
        );
      case _DxfInsertRef():
        return e; // unreachable: callers expand nested INSERTs first
      default:
        return e;
    }
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
      case _DxfInsertRef(
          :var blockName,
          :var position,
          :var scaleX,
          :var scaleY,
          :var rotationDeg
        ):
        // A nested INSERT on layer "0" inherits the outer INSERT's layer.
        return _DxfInsertRef(
          layer: layer,
          blockName: blockName,
          position: position,
          scaleX: scaleX,
          scaleY: scaleY,
          rotationDeg: rotationDeg,
        );
      default:
        return e;
    }
  }

  // ------------------------------------------------------------ helpers

  /// Expands a polyline's (point, bulge) pairs into plain vertices:
  /// straight segments stay as-is, bulged segments become arc points.
  List<DxfPoint> _expandBulges(
      List<(DxfPoint, double)> raw, bool closed) {
    final out = <DxfPoint>[];
    final n = raw.length;
    if (n == 0) return out;
    final segs = closed ? n : n - 1;
    for (var i = 0; i < segs; i++) {
      final (p0, bulge) = raw[i];
      final p1 = raw[(i + 1) % n].$1;
      if (i == 0) out.add(p0);
      final isClosing = closed && i == segs - 1;
      if (bulge == 0 || (p0.x == p1.x && p0.y == p1.y)) {
        // Straight segment; on the closing segment the end point is the
        // start point again, so it is not duplicated.
        if (!isClosing) out.add(p1);
      } else {
        final pts = _bulgeArcPoints(p0, p1, bulge);
        // pts runs p0..p1; p0 is already in the list, and on the closing
        // segment p1 is the start point again.
        out.addAll(pts.sublist(1, isClosing ? pts.length - 1 : pts.length));
      }
    }
    return out;
  }

  /// Points along the arc from [p0] to [p1] with the given DXF bulge
  /// (tan of a quarter of the included angle; positive = counter-
  /// clockwise). Includes both endpoints.
  List<DxfPoint> _bulgeArcPoints(DxfPoint p0, DxfPoint p1, double bulge) {
    final dx = p1.x - p0.x;
    final dy = p1.y - p0.y;
    final chord = math.sqrt(dx * dx + dy * dy);
    if (chord == 0 || bulge == 0) return [p0, p1];
    final mx = (p0.x + p1.x) / 2;
    final my = (p0.y + p1.y) / 2;
    // Center on the perpendicular bisector; bulge > 0 puts the center on
    // the left of the direction of travel (counter-clockwise arc).
    final h = (chord / 2) * (1 - bulge * bulge) / (2 * bulge);
    final ux = dx / chord;
    final uy = dy / chord;
    final cx = mx + -uy * h;
    final cy = my + ux * h;
    final r = math.sqrt(
        (p0.x - cx) * (p0.x - cx) + (p0.y - cy) * (p0.y - cy));
    final a0 = math.atan2(p0.y - cy, p0.x - cx);
    var sweepDeg = (math.atan2(p1.y - cy, p1.x - cx) - a0) * 180 / math.pi;
    if (bulge > 0) {
      sweepDeg %= 360;
      if (sweepDeg <= 0) sweepDeg += 360;
    } else {
      sweepDeg %= 360;
      if (sweepDeg >= 0) sweepDeg -= 360;
    }
    final n = dxfSegmentsForSweep(sweepDeg);
    final sweepRad = sweepDeg * math.pi / 180;
    return [
      for (var i = 0; i <= n; i++)
        () {
          final a = a0 + sweepRad * i / n;
          return DxfPoint(cx + r * math.cos(a), cy + r * math.sin(a));
        }(),
    ];
  }

  /// Strips MTEXT formatting: paragraph breaks, backslash codes
  /// (\F...; \H...; \S...; ...), braces, and %% special characters.
  String _cleanMText(String raw) {
    var t = raw.replaceAll(r'\P', '\n').replaceAll(r'\p', '\n');
    t = t.replaceAllMapped(RegExp(r'\\[A-Za-z][^;]*;'), (_) => '');
    t = t.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
    t = t.replaceAll(RegExp(r'[{}]'), '');
    t = t
        .replaceAll('%%d', '°')
        .replaceAll('%%p', '±')
        .replaceAll('%%c', 'ø');
    return t.trim();
  }

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

  double _parseDouble(String v, double fallback) {
    final parsed = double.tryParse(v.trim());
    // 'NaN' parses but is not a coordinate, and '1e999' parses to
    // Infinity — both would poison bounds and break jsonEncode later.
    if (parsed == null || !parsed.isFinite) return fallback;
    return parsed;
  }
}

/// One BLOCK definition: its base point plus its entities.
class _BlockDef {
  _BlockDef(this.base, this.entities);
  final DxfPoint base;
  final List<DxfEntity> entities;
}

/// General 2D affine transform (2x2 matrix + translation), used to expand
/// INSERTs: it composes exactly, so nested INSERTs, block base points and
/// non-uniform scales with rotation (shear) are handled instead of
/// silently dropped.
class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.tx, this.ty);
  final double a, b, c, d, tx, ty;

  /// The transform for an INSERT of a block whose base point is [base]:
  /// insert + R*S*(p - base).
  factory _Affine.fromInsert(_DxfInsertRef ins, DxfPoint base) {
    final rad = ins.rotationDeg * math.pi / 180;
    final cosR = math.cos(rad);
    final sinR = math.sin(rad);
    final bx = base.x * ins.scaleX;
    final by = base.y * ins.scaleY;
    final rbx = bx * cosR - by * sinR;
    final rby = bx * sinR + by * cosR;
    return _Affine(
      ins.scaleX * cosR,
      -ins.scaleY * sinR,
      ins.scaleX * sinR,
      ins.scaleY * cosR,
      ins.position.x - rbx,
      ins.position.y - rby,
    );
  }

  DxfPoint apply(DxfPoint p) =>
      DxfPoint(a * p.x + b * p.y + tx, c * p.x + d * p.y + ty);

  /// The transform that applies [other] first, then this one.
  _Affine compose(_Affine other) => _Affine(
        a * other.a + b * other.c,
        a * other.b + b * other.d,
        c * other.a + d * other.c,
        c * other.b + d * other.d,
        a * other.tx + b * other.ty + tx,
        c * other.tx + d * other.ty + ty,
      );

  /// True when the linear part is a rotation times (possibly non-uniform)
  /// scale — i.e. representable as a [DxfTransform] (no shear). That is
  /// the case exactly when the matrix columns are orthogonal.
  bool get isRotationScale {
    final dot = a * b + c * d;
    final mag = a * a + c * c + b * b + d * d;
    return dot.abs() < 1e-9 * (mag + 1e-12);
  }

  /// Converts to a [DxfTransform] when representable, else null.
  DxfTransform? toDxfTransform() {
    if (!isRotationScale) return null;
    final sx = math.sqrt(a * a + c * c);
    final det = a * d - b * c;
    final sy = (det < 0 ? -1 : 1) * math.sqrt(b * b + d * d);
    final rot = math.atan2(c, a) * 180 / math.pi;
    return DxfTransform(
      dx: tx,
      dy: ty,
      scaleX: sx,
      scaleY: sy,
      rotationDeg: rot,
    );
  }
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
