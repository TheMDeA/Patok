import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:patok/src/geopdf/georef.dart';
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

const _wgs84Utm50sWkt = 'PROJCS["WGS 84 / UTM zone 50S",'
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
      final objStmData =
          Uint8List.fromList(ascii.encode('$header$obj5\n$obj6'));
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
      write('4 0 obj\n<< /Type /ObjStm /N 2 /First ${header.length} '
          '/Length ${objStmCompressed.length} /Filter /FlateDecode >>\n'
          'stream\n');
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
      write('7 0 obj\n<< /Type /XRef /Size 8 /Root 1 0 R '
          '/W [1 2 2] /Index [1 6] '
          '/Length ${xrefData.length} /Filter /FlateDecode >>\n'
          'stream\n');
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
}
