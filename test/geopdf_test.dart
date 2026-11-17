import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:patok/src/geopdf/georef.dart';
import 'package:patok/src/models.dart';
import 'package:patok/src/geopdf/pdf_model.dart';
import 'package:patok/src/geopdf/pdf_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a minimal PDF with a classic xref table from indirect objects.
Uint8List buildPdf(List<String> objects) {
  final buf = <int>[];
  void write(String s) => buf.addAll(ascii.encode(s));
  write('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buf.length);
    write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefPos = buf.length;
  write('xref\n0 ${objects.length + 1}\n');
  write('0000000000 65535 f \n');
  for (final o in offsets) {
    write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n');
  write('startxref\n$xrefPos\n%%EOF\n');
  return Uint8List.fromList(buf);
}

const _wgs84Utm50sWkt =
    'PROJCS["WGS 84 / UTM zone 50S",'
    'GEOGCS["WGS 84",DATUM["WGS_1984",'
    'SPHEROID["WGS 84",6378137,298.257223563]],'
    'PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],'
    'PROJECTION["Transverse_Mercator"],'
    'PARAMETER["latitude_of_origin",0],'
    'PARAMETER["central_meridian",117],'
    'PARAMETER["scale_factor",0.9996],'
    'PARAMETER["false_easting",500000],'
    'PARAMETER["false_northing",10000000],'
    'UNIT["metre",1]]';

void main() {
  group('PdfParser', () {
    test('parses classic xref and walks to pages', () {
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final pages = parser.pages;
      expect(pages.length, 1);
      final mb = parser.deref(pages[0]['MediaBox']) as PdfArray;
      expect(mb.numbers, [0, 0, 612, 792]);
    });

    test('parses names, strings, hex strings, nested structures', () {
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/Title (Hello \\(world\\)) /ID <A1B2> '
            '/Info << /A true /B false /C null /D 12.5 >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final page = parser.pages.single;
      expect(page.stringValue('Title'), 'Hello (world)');
      expect((page['ID'] as PdfHexString).bytes, [0xA1, 0xB2]);
      final info = page.dict('Info')!;
      expect((info['A'] as PdfBool).value, isTrue);
      expect((info['C'] as PdfObject), isA<PdfNull>());
      expect(info.number('D'), 12.5);
    });

    test('parses xref stream + object stream (FlateDecode)', () {
      // Objects 1-3 live in the classic part; 4 is an ObjStm holding
      // objects 5 and 6; the xref itself is a stream (object 7).
      final obj5 = '<< /Type /Annot >>';
      final obj6 = '[1 2 3]';
      final off2 = obj5.length + 1; // + newline separator
      final header = '5 0\n6 $off2\n';
      final objStmData = Uint8List.fromList(
        ascii.encode('$header$obj5\n$obj6'),
      );
      final objStmCompressed = ZLibCodec().encode(objStmData);

      final buf = <int>[];
      void write(String s) => buf.addAll(ascii.encode(s));
      write('%PDF-1.7\n');
      final offsets = <int>[];
      final objs = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] '
            '/Annots 5 0 R /Extra 6 0 R >>',
      ];
      for (var i = 0; i < objs.length; i++) {
        offsets.add(buf.length);
        write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
      }
      // object 4: ObjStm
      final stm4Offset = buf.length;
      write(
        '4 0 obj\n<< /Type /ObjStm /N 2 /First ${header.length} '
        '/Length ${objStmCompressed.length} /Filter /FlateDecode >>\n'
        'stream\n',
      );
      buf.addAll(objStmCompressed);
      write('\nendstream\nendobj\n');
      // object 7: xref stream. Entries: 1..4 direct, 5..6 compressed in 4.
      // W = [1 2 2]: type(1) + field2(2) + field3(2)
      final entries = <int>[];
      void entry(int type, int f2, int f3) {
        entries.add(type);
        entries.addAll([(f2 >> 8) & 0xFF, f2 & 0xFF]);
        entries.addAll([(f3 >> 8) & 0xFF, f3 & 0xFF]);
      }

      entry(1, offsets[0], 0);
      entry(1, offsets[1], 0);
      entry(1, offsets[2], 0);
      entry(1, stm4Offset, 0);
      entry(2, 4, 0); // obj 5 in stream 4, index 0
      entry(2, 4, 1); // obj 6 in stream 4, index 1
      // (index 0 = free entry placeholder handled by /Index)
      final xrefOffset = buf.length;
      final xrefData = ZLibCodec().encode(Uint8List.fromList(entries));
      write(
        '7 0 obj\n<< /Type /XRef /Size 8 /Root 1 0 R '
        '/W [1 2 2] /Index [1 6] '
        '/Length ${xrefData.length} /Filter /FlateDecode >>\n'
        'stream\n',
      );
      buf.addAll(xrefData);
      write('\nendstream\nendobj\n');
      write('startxref\n$xrefOffset\n%%EOF\n');

      final parser = PdfParser.parse(Uint8List.fromList(buf));
      final pages = parser.pages;
      expect(pages.length, 1);
      final annot = parser.deref(pages[0]['Annots']);
      expect((annot as PdfDict).nameValue('Type'), 'Annot');
      final extra = parser.deref(pages[0]['Extra']) as PdfArray;
      expect(extra.numbers, [1, 2, 3]);
    });

    test('PdfArray.numbers accepts string-encoded numbers', () {
      final arr = PdfArray([
        const PdfString('1.5'),
        const PdfNumber(2),
        const PdfString(' 3 '),
      ]);
      expect(arr.numbers, [1.5, 2.0, 3.0]);
      // ... but not non-numbers, and not NaN/Infinity masquerading as
      // a number: those must fail loudly, not poison a transform.
      expect(
        () => const PdfArray([PdfString('abc')]).numbers,
        throwsA(isA<PdfParseException>()),
      );
      expect(
        () => const PdfArray([PdfString('NaN')]).numbers,
        throwsA(isA<PdfParseException>()),
      );
      expect(
        () => const PdfArray([PdfString('1e999')]).numbers,
        throwsA(isA<PdfParseException>()),
      );
    });

    test('truncated xref stream throws PdfParseException, not RangeError',
        () {
      // XRef stream declares /W [1 2 2] /Index [1 2] (2 entries = 10
      // bytes) but the stream only carries 3 bytes: reading the fields
      // used to leak a raw RangeError out of the parser.
      final buf = <int>[];
      void write(String s) => buf.addAll(ascii.encode(s));
      write('%PDF-1.7\n');
      final offsets = <int>[];
      final objs = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>',
      ];
      for (var i = 0; i < objs.length; i++) {
        offsets.add(buf.length);
        write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
      }
      final xrefOffset = buf.length;
      final xrefData = ZLibCodec().encode(Uint8List.fromList([1, 0, 0]));
      write(
        '4 0 obj\n<< /Type /XRef /Size 4 /Root 1 0 R '
        '/W [1 2 2] /Index [1 2] '
        '/Length ${xrefData.length} /Filter /FlateDecode >>\n'
        'stream\n',
      );
      buf.addAll(xrefData);
      write('\nendstream\nendobj\n');
      write('startxref\n$xrefOffset\n%%EOF\n');

      expect(
        () => PdfParser.parse(Uint8List.fromList(buf)),
        throwsA(isA<PdfParseException>()),
      );
    });

    test('object stream with PNG predictor decodes correctly', () {
      // Plain object-stream data: header + two objects, padded to a
      // whole number of 8-byte rows; rows use PNG filters 0 (None),
      // 1 (Sub) and 2 (Up) so the reconstruction paths are exercised.
      const obj5 = '<< /Type /Annot >>';
      const obj6 = '[1 2 3]';
      final header = '5 0\n6 ${obj5.length + 1}\n';
      final plain = Uint8List.fromList(
        ascii.encode('$header$obj5\n$obj6').toList()
          ..addAll(List<int>.filled(5, 32)), // pad 35 -> 40 bytes
      );
      const rowLen = 8;
      const filters = [0, 1, 2, 0, 0];
      final encoded = <int>[];
      var prevRow = List<int>.filled(rowLen, 0);
      for (var r = 0; r < filters.length; r++) {
        final row = plain.sublist(r * rowLen, (r + 1) * rowLen);
        encoded.add(filters[r]);
        for (var i = 0; i < rowLen; i++) {
          final a = i >= 1 ? row[i - 1] : 0;
          final b = prevRow[i];
          final pred = switch (filters[r]) {
            1 => a,
            2 => b,
            _ => 0,
          };
          encoded.add((row[i] - pred) & 0xFF);
        }
        prevRow = row.toList();
      }
      final objStmCompressed = ZLibCodec().encode(
        Uint8List.fromList(encoded),
      );

      final buf = <int>[];
      void write(String s) => buf.addAll(ascii.encode(s));
      write('%PDF-1.7\n');
      final offsets = <int>[];
      final objs = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] '
            '/Annots 5 0 R /Extra 6 0 R >>',
      ];
      for (var i = 0; i < objs.length; i++) {
        offsets.add(buf.length);
        write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
      }
      // object 4: ObjStm with PNG predictor 15.
      final stm4Offset = buf.length;
      write(
        '4 0 obj\n<< /Type /ObjStm /N 2 /First ${header.length} '
        '/Length ${objStmCompressed.length} /Filter /FlateDecode '
        '/DecodeParms << /Predictor 15 /Columns 8 /Colors 1 >> >>\n'
        'stream\n',
      );
      buf.addAll(objStmCompressed);
      write('\nendstream\nendobj\n');
      // object 7: xref stream. Entries: 1..4 direct, 5..6 compressed.
      final entries = <int>[];
      void entry(int type, int f2, int f3) {
        entries.add(type);
        entries.addAll([(f2 >> 8) & 0xFF, f2 & 0xFF]);
        entries.addAll([(f3 >> 8) & 0xFF, f3 & 0xFF]);
      }

      entry(1, offsets[0], 0);
      entry(1, offsets[1], 0);
      entry(1, offsets[2], 0);
      entry(1, stm4Offset, 0);
      entry(2, 4, 0);
      entry(2, 4, 1);
      final xrefOffset = buf.length;
      final xrefData = ZLibCodec().encode(Uint8List.fromList(entries));
      write(
        '7 0 obj\n<< /Type /XRef /Size 8 /Root 1 0 R '
        '/W [1 2 2] /Index [1 6] '
        '/Length ${xrefData.length} /Filter /FlateDecode >>\n'
        'stream\n',
      );
      buf.addAll(xrefData);
      write('\nendstream\nendobj\n');
      write('startxref\n$xrefOffset\n%%EOF\n');

      final parser = PdfParser.parse(Uint8List.fromList(buf));
      final annot = parser.deref(parser.pages.single['Annots']);
      expect((annot as PdfDict).nameValue('Type'), 'Annot');
      final extra = parser.deref(parser.pages.single['Extra']) as PdfArray;
      expect(extra.numbers, [1, 2, 3]);
    });
  });

  group('GeorefExtractor', () {
    test('extracts OGC /VP /Measure georeferencing', () {
      // GPTS pairs are (lat, lon): (0,0)->(106.8,-6.2),
      // (612,0)->(106.9,-6.2), (612,792)->(106.9,-6.3).
      // LPTS here are already in page points, so no BBox folding.
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/VP [4 0 R] >>',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 5 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.2 106.8 -6.2 106.9 -6.3 106.9] '
            '/LPTS [0 0 612 0 612 792] '
            '/GCS << /WKT (GEOGCS["WGS 84"]) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      final g = georefs.single;
      expect(g.kind.toString(), contains('ogc'));
      expect(g.srcIsLonLat, isTrue);
      // Exact fit through 3 points: check the 4th corner.
      final lon = g.a * 0 + g.b * 792 + g.c;
      final lat = g.d * 0 + g.e * 792 + g.f;
      expect(lon, closeTo(106.8, 1e-9));
      expect(lat, closeTo(-6.3, 1e-9));
    });

    test('OGC with viewport-normalized LPTS folds BBox into the affine', () {
      // Avenza-style: LPTS ~0..1 normalized to /BBox; GPTS are (lat, lon).
      // (0,0)->(106.8,-6.3), (1,0)->(106.9,-6.3), (1,1)->(106.9,-6.2).
      // LPTS y runs DOWN from the top of the viewport.
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
            '/VP [4 0 R] >>',
        '<< /Type /Viewport /BBox [0 0 200 100] /Measure 5 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.3 106.8 -6.3 106.9 -6.2 106.9] '
            '/LPTS [0 0 1 0 1 1] '
            '/GCS << /WKT (GEOGCS["WGS 84"]) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      final g = georefs.single;
      // Page corners must map through the folded affine:
      // top-left (0,100) -> (106.8,-6.3), bottom-right (200,0) -> (106.9,-6.2),
      // bottom-left (0,0) -> (106.8,-6.2).
      var lon = g.a * 0 + g.b * 100 + g.c;
      var lat = g.d * 0 + g.e * 100 + g.f;
      expect(lon, closeTo(106.8, 1e-9));
      expect(lat, closeTo(-6.3, 1e-9));
      lon = g.a * 200 + g.b * 0 + g.c;
      lat = g.d * 200 + g.e * 0 + g.f;
      expect(lon, closeTo(106.9, 1e-9));
      expect(lat, closeTo(-6.2, 1e-9));
      lon = g.a * 0 + g.b * 0 + g.c;
      lat = g.d * 0 + g.e * 0 + g.f;
      expect(lon, closeTo(106.8, 1e-9));
      expect(lat, closeTo(-6.2, 1e-9));
    });

    test('extracts TerraGo /LGIDict /Registration with UTM WKT', () {
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/LGIDict 4 0 R >>',
        '<< /Registration [0 0 500000 9200000 '
            '612 0 500612 9200000 '
            '612 792 500612 9199208 '
            '0 792 500000 9199208] '
            '/Projection << /WKT ($_wgs84Utm50sWkt) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      final g = georefs.single;
      expect(g.kind.toString(), contains('terraGo'));
      expect(g.srcIsLonLat, isFalse);
      // PDF point (0,0) -> projected (500000, 9200000) -> lon/lat.
      final sx = g.a * 0 + g.b * 0 + g.c;
      final sy = g.d * 0 + g.e * 0 + g.f;
      expect(sx, closeTo(500000, 1e-6));
      expect(sy, closeTo(9200000, 1e-6));
      final ll = toLonLat(sx, sy, g.srcWkt);
      expect(ll.x, closeTo(117.0, 0.05)); // central meridian of zone 50
      expect(ll.y, closeTo(-7.24, 0.1));
    });

    test('returns empty for non-georeferenced PDF', () {
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>',
      ]);
      final parser = PdfParser.parse(pdf);
      expect(GeorefExtractor(parser).extractAll(), isEmpty);
    });

    test('accepts TerraGo /CTM encoded as PDF strings', () {
      // TerraGo's own example encodes the CTM as strings, and the
      // patent allows numbers "or a string representation". This used
      // to fail the whole import with a raw TypeError.
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/LGIDict 4 0 R >>',
        '<< /CTM [(35.28267) (0) (0) (35.28267) (205188.64) (3207094.8)] '
            '/Projection << /WKT ($_wgs84Utm50sWkt) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      final g = georefs.single;
      expect(g.kind.toString(), contains('terraGo'));
      expect(g.a, closeTo(35.28267, 1e-9));
      expect(g.b, closeTo(0, 1e-9));
      expect(g.c, closeTo(205188.64, 1e-6));
      expect(g.d, closeTo(0, 1e-9));
      expect(g.e, closeTo(35.28267, 1e-9));
      expect(g.f, closeTo(3207094.8, 1e-6));
    });

    test('accepts string-encoded /Registration, /MediaBox, /GPTS, /LPTS',
        () {
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [(0) (0) (612) (792)] '
            '/LGIDict 4 0 R >>',
        '<< /Registration [(0) (0) (500000) (9200000) '
            '(612) (0) (500612) (9200000) '
            '(612) (792) (500612) (9199208) '
            '(0) (792) (500000) (9199208)] '
            '/Projection << /WKT ($_wgs84Utm50sWkt) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      final g = georefs.single;
      expect(g.pageWidthPt, 612);
      expect(g.pageHeightPt, 792);
      expect(g.a * 0 + g.b * 0 + g.c, closeTo(500000, 1e-6));
      expect(g.d * 0 + g.e * 0 + g.f, closeTo(9200000, 1e-6));

      // And the OGC side: string GPTS/LPTS.
      final ogc = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/VP [4 0 R] >>',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 5 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [(-6.2) (106.8) (-6.2) (106.9) (-6.3) (106.9)] '
            '/LPTS [(0) (0) (612) (0) (612) (792)] '
            '/GCS << /WKT (GEOGCS["WGS 84"]) >> >>',
      ]);
      final ogcGeorefs = GeorefExtractor(PdfParser.parse(ogc)).extractAll();
      expect(ogcGeorefs.length, 1);
      expect(
        ogcGeorefs.single.a * 0 + ogcGeorefs.single.b * 792 +
            ogcGeorefs.single.c,
        closeTo(106.8, 1e-9),
      );
    });

    test('one bad page does not abort the import of the other pages', () {
      // Page 1 has collinear control points (all LPTS y=0): the affine
      // fit is singular. Page 2 is valid. Previously the throw aborted
      // the whole import and the valid page was never returned.
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/VP [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/VP [6 0 R] >>',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 7 0 R >>',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 8 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.2 106.8 -6.2 106.9 -6.2 106.9] '
            '/LPTS [0 0 612 0 306 0] >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.2 106.8 -6.2 106.9 -6.3 106.9] '
            '/LPTS [0 0 612 0 612 792] '
            '/GCS << /WKT (GEOGCS["WGS 84"]) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final extractor = GeorefExtractor(parser);
      final georefs = extractor.extractAll();
      expect(georefs.length, 1);
      expect(georefs.single.pageIndex, 1);
      expect(extractor.pageErrors.length, 1);
      expect(extractor.pageErrors.single, contains('Page 1'));
    });

    test('a throwing first viewport does not block the next one', () {
      // The first viewport's /Measure is a dangling reference; the
      // second viewport is valid and must still win.
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/VP [4 0 R 5 0 R] >>',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 99 0 R >>',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 6 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.2 106.8 -6.2 106.9 -6.3 106.9] '
            '/LPTS [0 0 612 0 612 792] '
            '/GCS << /WKT (GEOGCS["WGS 84"]) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final extractor = GeorefExtractor(parser);
      final georefs = extractor.extractAll();
      expect(georefs.length, 1);
      expect(georefs.single.kind.toString(), contains('ogc'));
      // The broken viewport was skipped, not reported as a page failure:
      // the page itself imported cleanly.
      expect(extractor.pageErrors, isEmpty);
    });

    test('resolves indirect /Rotate and indirect /WKT', () {
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
            '/Rotate 4 0 R /VP [5 0 R] >>',
        '90',
        '<< /Type /Viewport /BBox [0 0 612 792] /Measure 6 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.2 106.8 -6.2 106.9 -6.3 106.9] '
            '/LPTS [0 0 612 0 612 792] '
            '/GCS << /WKT 7 0 R >> >>',
        '(GEOGCS["WGS 84"])',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      expect(georefs.single.rotation, 90);
      expect(georefs.single.srcWkt, 'GEOGCS["WGS 84"]');
    });

    test('small page-points LPTS are not treated as normalized', () {
      // A 40x40pt page whose control points are in page points: the old
      // < 50 heuristic misclassified these as viewport-normalized and
      // folded a bogus BBox scaling into the affine.
      final pdf = buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 40 40] '
            '/VP [4 0 R] >>',
        '<< /Type /Viewport /BBox [0 0 40 40] /Measure 5 0 R >>',
        '<< /Subtype /GEO '
            '/GPTS [-6.2 106.8 -6.2 106.9 -6.3 106.9] '
            '/LPTS [0 0 40 0 40 40] '
            '/GCS << /WKT (GEOGCS["WGS 84"]) >> >>',
      ]);
      final parser = PdfParser.parse(pdf);
      final georefs = GeorefExtractor(parser).extractAll();
      expect(georefs.length, 1);
      final g = georefs.single;
      // Page corners map through the unfolded affine:
      // (0,0)->(106.8,-6.2), (40,0)->(106.9,-6.2), (40,40)->(106.9,-6.3).
      expect(g.a * 0 + g.b * 0 + g.c, closeTo(106.8, 1e-9));
      expect(g.d * 0 + g.e * 0 + g.f, closeTo(-6.2, 1e-9));
      expect(g.a * 40 + g.b * 0 + g.c, closeTo(106.9, 1e-9));
      expect(g.a * 40 + g.b * 40 + g.c, closeTo(106.9, 1e-9));
      expect(g.d * 40 + g.e * 40 + g.f, closeTo(-6.3, 1e-9));
    });
  });

  group('affine + pixel mapping', () {
    test('fitAffine recovers a known transform', () {
      // u = 2x + 3y + 5, v = -x + 0.5y - 7
      final src = [
        math.Point(0.0, 0.0),
        math.Point(10.0, 0.0),
        math.Point(0.0, 10.0),
        math.Point(7.0, 3.0),
      ];
      final dst = [
        for (final p in src)
          math.Point(2 * p.x + 3 * p.y + 5, -p.x + 0.5 * p.y - 7),
      ];
      final f = fitAffine(src, dst);
      expect(f[0], closeTo(2, 1e-9));
      expect(f[1], closeTo(3, 1e-9));
      expect(f[2], closeTo(5, 1e-9));
      expect(f[3], closeTo(-1, 1e-9));
      expect(f[4], closeTo(0.5, 1e-9));
      expect(f[5], closeTo(-7, 1e-9));
    });

    test('fitAffine rejects a fit that misses its control points', () {
      // First three points are an exact transform; the fourth is wildly
      // off. The least-squares solve alone returns silently wrong
      // coefficients; the residual check must throw instead.
      final src = [
        math.Point(0.0, 0.0),
        math.Point(10.0, 0.0),
        math.Point(0.0, 10.0),
        math.Point(10.0, 10.0),
      ];
      final dst = [
        math.Point(5.0, -7.0),
        math.Point(25.0, -17.0),
        math.Point(35.0, -2.0),
        math.Point(999.0, 999.0),
      ];
      expect(() => fitAffine(src, dst), throwsArgumentError);
    });

    test('pixelToUserSpace without rotation', () {
      final p = pixelToUserSpace(
        px: 0,
        py: 0,
        imgW: 612,
        imgH: 792,
        pageW: 612,
        pageH: 792,
        rotation: 0,
      );
      expect(p.x, closeTo(0, 1e-9));
      expect(p.y, closeTo(792, 1e-9)); // top-left pixel -> top-left of page
      final q = pixelToUserSpace(
        px: 612,
        py: 792,
        imgW: 612,
        imgH: 792,
        pageW: 612,
        pageH: 792,
        rotation: 0,
      );
      expect(q.x, closeTo(612, 1e-9));
      expect(q.y, closeTo(0, 1e-9));
    });

    test('pixelToUserSpace with 90-degree rotation', () {
      // Page 612x792, /Rotate 90 -> rendered 792x612.
      final p = pixelToUserSpace(
        px: 0,
        py: 0,
        imgW: 792,
        imgH: 612,
        pageW: 612,
        pageH: 792,
        rotation: 90,
      );
      // Displayed top-left pixel: rotated (0,612) -> unrotated (612-612, 0)=(0,0)
      expect(p.x, closeTo(0, 1e-9));
      expect(p.y, closeTo(0, 1e-9));
    });

    test('formatUtm produces a zone string', () {
      final s = formatUtm(106.8, -6.2);
      expect(s, contains('48S')); // lon 106.8E -> UTM zone 48S
    });
  });

  group('detail render transforms', () {
    // pixelToUserSpace and userToRotatedPx must be exact inverses for all
    // /Rotate values: the detail overlay depends on it.
    test('userToRotatedPx inverts pixelToUserSpace', () {
      const pageW = 612.0, pageH = 792.0;
      for (final rotation in [0, 90, 180, 270]) {
        final rotW = (rotation == 90 || rotation == 270) ? pageH : pageW;
        final rotH = (rotation == 90 || rotation == 270) ? pageW : pageH;
        const scale = 2.5;
        final fullW = rotW * scale, fullH = rotH * scale;
        for (final u in [
          [0.0, 0.0],
          [pageW, pageH],
          [pageW / 2, pageH / 3],
          [123.4, 456.7],
        ]) {
          final px = userToRotatedPx(
            u[0],
            u[1],
            scale: scale,
            pageW: pageW,
            pageH: pageH,
            rotation: rotation,
            fullH: fullH,
          );
          final back = pixelToUserSpace(
            px: px.x,
            py: px.y,
            imgW: fullW,
            imgH: fullH,
            pageW: pageW,
            pageH: pageH,
            rotation: rotation,
          );
          expect(
            (back.x - u[0]).abs() < 1e-9,
            isTrue,
            reason: 'rot=$rotation u=$u -> $back',
          );
          expect(
            (back.y - u[1]).abs() < 1e-9,
            isTrue,
            reason: 'rot=$rotation u=$u -> $back',
          );
        }
      }
    });

    test('inverseAffine inverts the page affine', () {
      final g = PageGeoref(
        pageIndex: 0,
        pageWidthPt: 612,
        pageHeightPt: 792,
        rotation: 0,
        kind: GeorefKind.ogc,
        a: 0.001,
        b: 0.0002,
        c: 115.0,
        d: -0.0001,
        e: -0.0011,
        f: -2.0,
        srcIsLonLat: true,
      );
      for (final u in [
        [0.0, 0.0],
        [612.0, 792.0],
        [300.5, 400.25],
      ]) {
        final sx = g.a * u[0] + g.b * u[1] + g.c;
        final sy = g.d * u[0] + g.e * u[1] + g.f;
        final back = inverseAffine(g, sx, sy);
        expect((back.x - u[0]).abs() < 1e-9, isTrue);
        expect((back.y - u[1]).abs() < 1e-9, isTrue);
      }
    });

    test('toProjected falls back to identity without wkt', () {
      final p = toProjected(115.5, -2.1, null);
      expect(p.x, 115.5);
      expect(p.y, -2.1);
    });

    test('toLonLat/toProjected throw on a bad WKT instead of identity',
        () {
      // Previously a bad WKT silently returned the input unchanged, so
      // a TerraGo page imported with corners like lon=500000.
      expect(
        () => toLonLat(500000, 9200000, 'this is not a projection'),
        throwsArgumentError,
      );
      expect(
        () => toProjected(117.0, -7.0, 'this is not a projection'),
        throwsArgumentError,
      );
      // ... and on a non-finite result from a valid projection.
      expect(
        () => toLonLat(1e308, 9200000, _wgs84Utm50sWkt),
        throwsArgumentError,
      );
      // Null/empty WKT still means "already lon/lat".
      final p = toLonLat(106.8, -6.2, null);
      expect(p.x, 106.8);
      expect(p.y, -6.2);
    });
  });

  group('polygonAreaSqMeters', () {
    test('1x1 degree square at equator ~ 12,364 km²', () {
      final area = polygonAreaSqMeters([
        [0.0, 0.0],
        [1.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0],
      ]);
      // (111.32km)² ≈ 12392 km²; equirectangular slightly under.
      expect(area, greaterThan(12.2e9));
      expect(area, lessThan(12.6e9));
    });

    test('100m x 100m square', () {
      // 0.0008983° ≈ 100m at equator.
      const d = 0.0008983;
      final area = polygonAreaSqMeters([
        [115.5, -2.1],
        [115.5 + d, -2.1],
        [115.5 + d, -2.1 + d],
        [115.5, -2.1 + d],
      ]);
      expect(area, greaterThan(9900));
      expect(area, lessThan(10100));
    });

    test('degenerate input returns 0', () {
      expect(polygonAreaSqMeters([]), 0);
      expect(
        polygonAreaSqMeters([
          [1.0, 2.0],
          [3.0, 4.0],
        ]),
        0,
      );
    });
  });
}
