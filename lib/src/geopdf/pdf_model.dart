import 'dart:typed_data';

/// Minimal PDF object model — just enough to read document structure
/// and georeferencing dictionaries. Not a general-purpose PDF library.
sealed class PdfObject {
  const PdfObject();
}

class PdfNull extends PdfObject {
  const PdfNull();
  @override
  String toString() => 'null';
}

class PdfBool extends PdfObject {
  final bool value;
  const PdfBool(this.value);
  @override
  String toString() => '$value';
}

class PdfNumber extends PdfObject {
  final double value;
  const PdfNumber(this.value);
  int get asInt => value.toInt();
  @override
  String toString() => '$value';
}

class PdfName extends PdfObject {
  /// Decoded name without the leading slash.
  final String name;
  const PdfName(this.name);
  @override
  String toString() => '/$name';
}

class PdfString extends PdfObject {
  /// Literal string with PDF escapes decoded (as Dart string).
  final String value;
  const PdfString(this.value);
  @override
  String toString() => '($value)';
}

class PdfHexString extends PdfObject {
  final Uint8List bytes;
  const PdfHexString(this.bytes);
  String get asLatin1 => String.fromCharCodes(bytes);
  @override
  String toString() => '<${bytes.length} bytes>';
}

class PdfArray extends PdfObject {
  final List<PdfObject> items;
  const PdfArray(this.items);

  /// All items as numbers (throws if any item is not a number).
  List<double> get numbers =>
      items.map((e) => (e as PdfNumber).value).toList();

  @override
  String toString() => '[${items.length} items]';
}

class PdfDict extends PdfObject {
  final Map<String, PdfObject> entries;
  const PdfDict(this.entries);

  PdfObject? operator [](String key) => entries[key];

  PdfDict? dict(String key) {
    final v = entries[key];
    return v is PdfDict ? v : null;
  }

  PdfArray? array(String key) {
    final v = entries[key];
    return v is PdfArray ? v : null;
  }

  PdfName? name(String key) {
    final v = entries[key];
    return v is PdfName ? v : null;
  }

  String? nameValue(String key) => name(key)?.name;

  double? number(String key) {
    final v = entries[key];
    return v is PdfNumber ? v.value : null;
  }

  String? stringValue(String key) {
    final v = entries[key];
    if (v is PdfString) return v.value;
    if (v is PdfHexString) return v.asLatin1;
    return null;
  }

  @override
  String toString() => '<<${entries.length} entries>>';
}

class PdfRef extends PdfObject {
  final int num;
  final int gen;
  const PdfRef(this.num, this.gen);
  @override
  String toString() => '$num $gen R';
}

class PdfStream extends PdfObject {
  final PdfDict dict;
  final Uint8List data;
  const PdfStream(this.dict, this.data);
  @override
  String toString() => 'stream(${data.length} bytes)';
}

/// Thrown when the PDF structure cannot be parsed.
class PdfParseException implements Exception {
  final String message;
  PdfParseException(this.message);
  @override
  String toString() => 'PdfParseException: $message';
}
