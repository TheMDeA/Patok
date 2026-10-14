import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pdf_model.dart';

/// Byte cursor with save/restore for lookahead.
class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int pos = 0;

  bool get eof => pos >= bytes.length;
  int peek() => eof ? -1 : bytes[pos];
  int read() => eof ? -1 : bytes[pos++];

  int save() => pos;
  void restore(int p) => pos = p;

  static bool isWhitespace(int c) =>
      c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
  static bool isDelimiter(int c) =>
      c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 ||
      c == 123 || c == 125 || c == 47 || c == 37;
  static bool isDigit(int c) => c >= 48 && c <= 57;

  void skipWhitespaceAndComments() {
    while (!eof) {
      final c = peek();
      if (isWhitespace(c)) {
        pos++;
      } else if (c == 37) {
        // comment: skip to end of line
        while (!eof && peek() != 10 && peek() != 13) {
          pos++;
        }
      } else {
        break;
      }
    }
  }

  /// Expects [s] at the current position (after skipping whitespace).
  void expect(String s) {
    skipWhitespaceAndComments();
    for (var i = 0; i < s.length; i++) {
      if (read() != s.codeUnitAt(i)) {
        throw PdfParseException('Expected "$s" at offset $pos');
      }
    }
  }

  bool tryKeyword(String s) {
    final p = save();
    skipWhitespaceAndComments();
    for (var i = 0; i < s.length; i++) {
      if (eof || bytes[pos++] != s.codeUnitAt(i)) {
        restore(p);
        return false;
      }
    }
    // keyword must not be followed by a regular char
    if (!eof && !isWhitespace(peek()) && !isDelimiter(peek())) {
      restore(p);
      return false;
    }
    return true;
  }
}

class _XrefEntry {
  /// Direct object at file offset, or compressed object.
  final int? offset;
  final int? streamObjNum;
  final int? streamIndex;
  final int gen;
  const _XrefEntry.direct(this.offset, this.gen)
      : streamObjNum = null,
        streamIndex = null;
  const _XrefEntry.compressed(this.streamObjNum, this.streamIndex)
      : offset = null,
        gen = 0;
}

/// Minimal PDF parser: xref tables/streams, object streams, FlateDecode
/// (with PNG predictors), and full object syntax. Enough to walk the
/// document catalog and read georeferencing dictionaries.
class PdfParser {
  PdfParser._(this._bytes);

  final Uint8List _bytes;
  final Map<int, _XrefEntry> _entries = {};
  final Map<int, PdfObject> _cache = {};
  final Map<int, List<PdfObject>> _objStmCache = {};
  PdfDict? _trailerDict;
  PdfDict get trailer => _trailerDict!;

  factory PdfParser.parse(Uint8List bytes) {
    final p = PdfParser._(bytes);
    p._parseXrefChain();
    return p;
  }

  // ---------------------------------------------------------------- xref

  void _parseXrefChain() {
    final xrefOffset = _findStartXref();
    var offset = xrefOffset;
    var first = true;
    while (true) {
      final next = _parseXrefAt(offset, first);
      if (next == null) break;
      offset = next;
      first = false;
    }
    if (_trailerDict == null || _trailerDict!.entries.isEmpty) {
      throw PdfParseException('No trailer dictionary found');
    }
  }

  int _findStartXref() {
    // "startxref" appears near the end of the file; take the LAST one.
    final needle = ascii.encode('startxref');
    var last = -1;
    for (var i = _bytes.length - needle.length; i >= 0; i--) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (_bytes[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        last = i;
        break;
      }
    }
    if (last < 0) throw PdfParseException('startxref not found');
    final c = _Cursor(_bytes)..pos = last + needle.length;
    c.skipWhitespaceAndComments();
    final num = _parseAsciiInt(c);
    return num;
  }

  int _parseAsciiInt(_Cursor c) {
    c.skipWhitespaceAndComments();
    final sb = StringBuffer();
    while (!c.eof && _Cursor.isDigit(c.peek())) {
      sb.writeCharCode(c.read());
    }
    if (sb.isEmpty) throw PdfParseException('Expected integer at ${c.pos}');
    return int.parse(sb.toString());
  }

  /// Parses one xref section; returns the /Prev offset or null.
  int? _parseXrefAt(int offset, bool first) {
    final c = _Cursor(_bytes)..pos = offset;
    c.skipWhitespaceAndComments();
    if (c.tryKeyword('xref')) {
      return _parseClassicXref(c);
    }
    // Otherwise it must be an xref stream: "n g obj" + stream dict.
    final objNum = _parseAsciiInt(c);
    final gen = _parseAsciiInt(c);
    c.expect('obj');
    final obj = _parseObject(c);
    if (obj is! PdfStream) {
      throw PdfParseException('Expected xref stream at $offset');
    }
    _parseXrefStream(objNum, gen, obj);
    return null; // /Prev handled inside via dict
  }

  int? _parseClassicXref(_Cursor c) {
    while (true) {
      c.skipWhitespaceAndComments();
      if (c.tryKeyword('trailer')) {
        final dict = _parseObject(c);
        if (dict is! PdfDict) {
          throw PdfParseException('Trailer is not a dictionary');
        }
        _trailerDict ??= dict;
        final prev = dict.number('Prev');
        return prev?.toInt();
      }
      // subsection: firstObj count
      final firstObj = _parseAsciiInt(c);
      final count = _parseAsciiInt(c);
      // consume end of line
      while (!c.eof && (c.peek() == 10 || c.peek() == 13)) {
        c.read();
      }
      for (var i = 0; i < count; i++) {
        final entryOffset = _parseFixedInt(c, 10);
        _expectByte(c, 32);
        final gen = _parseFixedInt(c, 5);
        _expectByte(c, 32);
        final kind = c.read(); // 'n' or 'f'
        // skip to end of line, then consume the line break
        while (!c.eof && c.peek() != 10 && c.peek() != 13) {
          c.read();
        }
        while (!c.eof && (c.peek() == 10 || c.peek() == 13)) {
          c.read();
        }
        if (kind == 110 /* n */) {
          final num = firstObj + i;
          _entries.putIfAbsent(
              num, () => _XrefEntry.direct(entryOffset, gen));
        }
      }
    }
  }

  int _parseFixedInt(_Cursor c, int digits) {
    var v = 0;
    for (var i = 0; i < digits; i++) {
      final ch = c.read();
      if (ch < 48 || ch > 57) {
        throw PdfParseException('Bad fixed int at ${c.pos}');
      }
      v = v * 10 + (ch - 48);
    }
    return v;
  }

  /// Expects one raw byte without skipping whitespace first
  /// ([_Cursor.expect] would skip the very byte we want to match).
  void _expectByte(_Cursor c, int byte) {
    if (c.read() != byte) {
      throw PdfParseException('Expected byte $byte at offset ${c.pos}');
    }
  }

  void _parseXrefStream(int objNum, int gen, PdfStream stream) {
    final dict = stream.dict;
    final w = dict.array('W');
    if (w == null || w.items.length != 3) {
      throw PdfParseException('XRef stream without /W');
    }
    final w1 = (w.items[0] as PdfNumber).asInt;
    final w2 = (w.items[1] as PdfNumber).asInt;
    final w3 = (w.items[2] as PdfNumber).asInt;
    final size = dict.number('Size')?.toInt() ?? 0;
    final indexArr = dict.array('Index');
    final raw = _decodeStreamData(stream);

    var p = 0;
    int readField(int width) {
      var v = 0;
      for (var i = 0; i < width; i++) {
        v = (v << 8) | raw[p++];
      }
      return v;
    }

    void handleRange(int first, int count) {
      for (var i = 0; i < count; i++) {
        final num = first + i;
        var type = 1;
        if (w1 > 0) type = readField(w1);
        final f2 = w2 > 0 ? readField(w2) : 0;
        final f3 = w3 > 0 ? readField(w3) : 0;
        if (type == 0) continue; // free
        if (type == 1) {
          _entries.putIfAbsent(num, () => _XrefEntry.direct(f2, f3));
        } else if (type == 2) {
          _entries.putIfAbsent(num, () => _XrefEntry.compressed(f2, f3));
        }
      }
    }

    if (indexArr != null) {
      final nums = indexArr.numbers.map((e) => e.toInt()).toList();
      for (var i = 0; i + 1 < nums.length; i += 2) {
        handleRange(nums[i], nums[i + 1]);
      }
    } else {
      handleRange(0, size);
    }

    _trailerDict ??= dict;
    final prev = dict.number('Prev');
    if (prev != null) {
      _parseXrefAt(prev.toInt(), false);
    }
  }

  // ------------------------------------------------------------- decode

  /// Decodes stream data according to /Filter (FlateDecode supported,
  /// with PNG/TIFF predictors).
  Uint8List _decodeStreamData(PdfStream stream) {
    var data = stream.data;
    final filter = stream.dict['Filter'];
    final filters = <String>[];
    if (filter is PdfName) {
      filters.add(filter.name);
    } else if (filter is PdfArray) {
      for (final f in filter.items) {
        if (f is PdfName) filters.add(f.name);
      }
    }
    final decodeParms = stream.dict['DecodeParms'];
    PdfDict? parms;
    if (decodeParms is PdfDict) {
      parms = decodeParms;
    } else if (decodeParms is PdfArray && decodeParms.items.isNotEmpty) {
      final first = decodeParms.items.first;
      if (first is PdfDict) parms = first;
    }
    for (final f in filters) {
      if (f == 'FlateDecode' || f == 'Fl') {
        data = Uint8List.fromList(ZLibCodec().decode(data));
        data = _applyPredictor(data, parms);
      } else {
        throw PdfParseException('Unsupported stream filter: $f');
      }
    }
    return data;
  }

  Uint8List _applyPredictor(Uint8List data, PdfDict? parms) {
    final predictor = parms?.number('Predictor')?.toInt() ?? 1;
    if (predictor == 1) return data;
    final columns = parms?.number('Columns')?.toInt() ?? 1;
    final colors = parms?.number('Colors')?.toInt() ?? 1;
    final bpc = parms?.number('BitsPerComponent')?.toInt() ?? 8;
    if (bpc != 8) {
      throw PdfParseException('Predictor with $bpc bpc not supported');
    }
    final rowLen = columns * colors;
    if (predictor == 2) {
      // TIFF horizontal differencing
      final out = Uint8List(data.length);
      var p = 0;
      while (p < data.length) {
        final len = (p + rowLen <= data.length) ? rowLen : data.length - p;
        for (var i = 0; i < len; i++) {
          final left = i >= colors ? out[p + i - colors] : 0;
          out[p + i] = (data[p + i] + left) & 0xFF;
        }
        p += len;
      }
      return out;
    }
    // PNG predictors 10-15: each row prefixed by filter type byte.
    final out = <int>[];
    var p = 0;
    var prevRow = List<int>.filled(rowLen, 0);
    while (p < data.length) {
      if (p + 1 + rowLen > data.length) break;
      final filterType = data[p++];
      final row = data.sublist(p, p + rowLen).toList();
      p += rowLen;
      final recon = List<int>.filled(rowLen, 0);
      for (var i = 0; i < rowLen; i++) {
        final a = i >= colors ? recon[i - colors] : 0;
        final b = prevRow[i];
        final c = i >= colors ? prevRow[i - colors] : 0;
        int pred;
        switch (filterType) {
          case 0:
            pred = 0;
            break;
          case 1:
            pred = a;
            break;
          case 2:
            pred = b;
            break;
          case 3:
            pred = (a + b) >> 1;
            break;
          case 4:
            pred = _paeth(a, b, c);
            break;
          default:
            throw PdfParseException('Bad PNG filter type $filterType');
        }
        recon[i] = (row[i] + pred) & 0xFF;
      }
      out.addAll(recon);
      prevRow = recon;
    }
    return Uint8List.fromList(out);
  }

  int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
  }

  // ------------------------------------------------------------- resolve

  /// Resolves indirect references (with caching).
  PdfObject deref(PdfObject? obj) {
    if (obj is! PdfRef) return obj ?? const PdfNull();
    final cached = _cache[obj.num];
    if (cached != null) return cached;
    final entry = _entries[obj.num];
    if (entry == null) {
      throw PdfParseException('Object ${obj.num} not in xref');
    }
    late final PdfObject result;
    if (entry.offset != null) {
      final c = _Cursor(_bytes)..pos = entry.offset!;
      _parseAsciiInt(c); // obj num
      _parseAsciiInt(c); // gen
      c.expect('obj');
      result = _parseObject(c);
    } else {
      final objs = _objStmObjects(entry.streamObjNum!);
      result = objs[entry.streamIndex!];
    }
    _cache[obj.num] = result;
    return result;
  }

  List<PdfObject> _objStmObjects(int stmNum) {
    final cached = _objStmCache[stmNum];
    if (cached != null) return cached;
    final stm = deref(PdfRef(stmNum, 0));
    if (stm is! PdfStream) {
      throw PdfParseException('Object $stmNum is not an object stream');
    }
    final data = _decodeStreamData(stm);
    final n = stm.dict.number('N')?.toInt() ?? 0;
    final first = stm.dict.number('First')?.toInt() ?? 0;
    final c = _Cursor(data);
    final offsets = <int>[];
    for (var i = 0; i < n; i++) {
      _parseAsciiInt(c); // object number (ignored, positional)
      offsets.add(_parseAsciiInt(c));
    }
    final objs = <PdfObject>[];
    for (var i = 0; i < n; i++) {
      c.pos = first + offsets[i];
      objs.add(_parseObject(c));
    }
    _objStmCache[stmNum] = objs;
    return objs;
  }

  PdfDict get catalog {
    final root = deref(trailer['Root']);
    if (root is! PdfDict) throw PdfParseException('No /Root in trailer');
    return root;
  }

  /// All page dictionaries in document order.
  List<PdfDict> get pages {
    final pagesRef = catalog['Pages'];
    final pagesDict = deref(pagesRef);
    if (pagesDict is! PdfDict) throw PdfParseException('No /Pages tree');
    final result = <PdfDict>[];
    void walk(PdfObject node) {
      final d = deref(node);
      if (d is! PdfDict) return;
      if (d.nameValue('Type') == 'Page') {
        result.add(d);
        return;
      }
      final kids = deref(d['Kids']);
      if (kids is PdfArray) {
        for (final k in kids.items) {
          walk(k);
        }
      }
    }

    walk(pagesDict);
    return result;
  }

  // ------------------------------------------------------------- objects

  PdfObject _parseObject(_Cursor c) {
    c.skipWhitespaceAndComments();
    if (c.eof) throw PdfParseException('Unexpected EOF');
    final ch = c.peek();

    if (ch == 40) return _parseLiteralString(c); // (
    if (ch == 60) {
      // <</hex
      if (c.pos + 1 < c.bytes.length && c.bytes[c.pos + 1] == 60) {
        return _parseDict(c);
      }
      return _parseHexString(c);
    }
    if (ch == 91) return _parseArray(c); // [
    if (ch == 47) return _parseName(c); // /
    if (ch == 62) throw PdfParseException('Unexpected >> at ${c.pos}');

    if (_Cursor.isDigit(ch) || ch == 43 || ch == 45 || ch == 46) {
      return _parseNumberOrRef(c);
    }
    // true / false / null
    if (c.tryKeyword('true')) return const PdfBool(true);
    if (c.tryKeyword('false')) return const PdfBool(false);
    if (c.tryKeyword('null')) return const PdfNull();
    throw PdfParseException(
        'Unexpected char ${String.fromCharCode(ch)} at ${c.pos}');
  }

  PdfObject _parseNumberOrRef(_Cursor c) {
    final num = _parseNumber(c);
    // lookahead: "int int R"
    final p2 = c.save();
    c.skipWhitespaceAndComments();
    if (num.value == num.value.toInt()) {
      try {
        final second = _parseNumber(c);
        c.skipWhitespaceAndComments();
        if (c.tryKeyword('R')) {
          return PdfRef(num.asInt, second.asInt);
        }
      } catch (_) {
        // not a reference; fall through
      }
    }
    c.restore(p2);
    // If we consumed nothing meaningful after, restore to right after number.
    // (p2 is right after the first number.)
    return num;
  }

  PdfNumber _parseNumber(_Cursor c) {
    c.skipWhitespaceAndComments();
    final sb = StringBuffer();
    var ch = c.peek();
    if (ch == 43 || ch == 45) sb.writeCharCode(c.read());
    var dot = false;
    while (!c.eof) {
      ch = c.peek();
      if (_Cursor.isDigit(ch)) {
        sb.writeCharCode(c.read());
      } else if (ch == 46 && !dot) {
        dot = true;
        sb.writeCharCode(c.read());
      } else {
        break;
      }
    }
    if (sb.isEmpty || sb.toString() == '+' || sb.toString() == '-') {
      throw PdfParseException('Bad number at ${c.pos}');
    }
    return PdfNumber(double.parse(sb.toString()));
  }

  PdfName _parseName(_Cursor c) {
    c.expect('/');
    final sb = StringBuffer();
    while (!c.eof) {
      final ch = c.peek();
      if (_Cursor.isWhitespace(ch) || _Cursor.isDelimiter(ch)) break;
      c.read();
      if (ch == 35) {
        // #XX hex escape
        final hex = String.fromCharCodes([c.read(), c.read()]);
        sb.writeCharCode(int.parse(hex, radix: 16));
      } else {
        sb.writeCharCode(ch);
      }
    }
    return PdfName(sb.toString());
  }

  PdfString _parseLiteralString(_Cursor c) {
    c.expect('(');
    final sb = StringBuffer();
    var depth = 1;
    while (!c.eof && depth > 0) {
      final ch = c.read();
      if (ch == 92) {
        // escape
        final e = c.read();
        switch (e) {
          case 110:
            sb.write('\n');
            break;
          case 114:
            sb.write('\r');
            break;
          case 116:
            sb.write('\t');
            break;
          case 98:
            sb.write('\b');
            break;
          case 102:
            sb.write('\f');
            break;
          case 40:
            sb.write('(');
            break;
          case 41:
            sb.write(')');
            break;
          case 92:
            sb.write('\\');
            break;
          case 10:
            break; // line continuation
          case 13:
            if (c.peek() == 10) c.read();
            break;
          default:
            if (e >= 48 && e <= 55) {
              // octal, up to 3 digits
              var oct = String.fromCharCode(e);
              for (var i = 0; i < 2; i++) {
                final d = c.peek();
                if (d >= 48 && d <= 55) {
                  oct += String.fromCharCode(c.read());
                } else {
                  break;
                }
              }
              sb.writeCharCode(int.parse(oct, radix: 8));
            } else {
              sb.writeCharCode(e);
            }
        }
      } else if (ch == 40) {
        depth++;
        sb.write('(');
      } else if (ch == 41) {
        depth--;
        if (depth > 0) sb.write(')');
      } else if (ch == 13) {
        sb.write('\n');
        if (c.peek() == 10) c.read();
      } else {
        sb.writeCharCode(ch);
      }
    }
    return PdfString(sb.toString());
  }

  PdfHexString _parseHexString(_Cursor c) {
    c.expect('<');
    final bytes = <int>[];
    var hi = -1;
    while (!c.eof) {
      final ch = c.read();
      if (ch == 62) break; // >
      if (_Cursor.isWhitespace(ch)) continue;
      final v = _hexVal(ch);
      if (hi < 0) {
        hi = v;
      } else {
        bytes.add((hi << 4) | v);
        hi = -1;
      }
    }
    if (hi >= 0) bytes.add(hi << 4);
    return PdfHexString(Uint8List.fromList(bytes));
  }

  int _hexVal(int ch) {
    if (ch >= 48 && ch <= 57) return ch - 48;
    if (ch >= 65 && ch <= 70) return ch - 55;
    if (ch >= 97 && ch <= 102) return ch - 87;
    throw PdfParseException('Bad hex char at stream');
  }

  PdfArray _parseArray(_Cursor c) {
    c.expect('[');
    final items = <PdfObject>[];
    while (true) {
      c.skipWhitespaceAndComments();
      if (c.peek() == 93) {
        c.read();
        break;
      }
      items.add(_parseObject(c));
    }
    return PdfArray(items);
  }

  PdfObject _parseDict(_Cursor c) {
    c.expect('<<');
    final entries = <String, PdfObject>{};
    while (true) {
      c.skipWhitespaceAndComments();
      if (c.peek() == 62) {
        c.expect('>>');
        break;
      }
      final key = _parseName(c);
      final value = _parseObject(c);
      entries[key.name] = value;
    }
    // A stream follows its dict directly: "... >> stream".
    final p = c.save();
    c.skipWhitespaceAndComments();
    if (c.tryKeyword('stream')) {
      return _parseStream(c, PdfDict(entries));
    }
    c.restore(p);
    return PdfDict(entries);
  }

  PdfStream _parseStream(_Cursor c, PdfDict dict) {
    // After 'stream' keyword: EOL is \r\n or \n (not part of data).
    if (c.peek() == 13) {
      c.read();
      if (c.peek() == 10) c.read();
    } else if (c.peek() == 10) {
      c.read();
    }
    final start = c.pos;
    // Length may be an indirect reference.
    var length = dict.number('Length')?.toInt();
    if (length == null) {
      final lenObj = deref(dict['Length']);
      if (lenObj is PdfNumber) length = lenObj.asInt;
    }
    if (length == null) throw PdfParseException('Stream without /Length');
    c.pos = start + length;
    c.skipWhitespaceAndComments();
    c.expect('endstream');
    final data = Uint8List.fromList(_bytes.sublist(start, start + length));
    return PdfStream(dict, data);
  }
}
