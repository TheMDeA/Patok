import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:patok/src/dxf/dxf_crs.dart';
import 'package:patok/src/dxf/dxf_import.dart';
import 'package:patok/src/models.dart';
import 'package:patok/src/services.dart';
import 'package:patok/src/waypoint_averaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// One georeferenced page (OGC /VP /Measure, lon/lat) for import tests.
Uint8List buildGeoPdf() => buildPdf([
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

const _dxfHeader = '''
0
SECTION
2
HEADER
0
ENDSEC
''';

const _dxfTables = '''
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
ENDTAB
0
ENDSEC
''';

String _dxfDoc(String body) => '''
$_dxfHeader
$_dxfTables
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

const _dxfLine = '''
0
LINE
8
PIT
10
500000.0
20
9200000.0
11
500100.0
21
9200100.0
''';

Position _fix(double lon, double lat) => Position(
      longitude: lon,
      latitude: lat,
      timestamp: DateTime.now(),
      accuracy: 3,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

GeoMap _testMap(String id, {String name = 'Test map'}) => GeoMap(
      id: id,
      name: name,
      fileName: '$name.pdf',
      pages: [
        GeoMapPage(
          pageIndex: 0,
          name: 'Map',
          georef: PageGeoref(
            pageIndex: 0,
            pageWidthPt: 612,
            pageHeightPt: 792,
            rotation: 0,
            kind: GeorefKind.ogc,
            a: 1,
            b: 0,
            c: 0,
            d: 0,
            e: 1,
            f: 0,
            srcIsLonLat: true,
          ),
          cornerLonLat: [
            [106.8, -6.2],
            [106.9, -6.2],
            [106.9, -6.3],
            [106.8, -6.3],
          ],
        ),
      ],
    );

/// A LocationService whose streams are fed by the test.
class _FakeLocation extends LocationService {
  _FakeLocation(this.stream);
  final StreamController<Position> stream;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<Position> positionStream() => stream.stream;

  @override
  Stream<Position> rawPositionStream() => stream.stream;
}

Future<void> _removeAny(String path) async {
  final type = await FileSystemEntity.type(path);
  if (type == FileSystemEntityType.file) {
    await File(path).delete();
  } else if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  }
}

void main() {
  late Directory docsDir;
  late Directory appDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    docsDir = await Directory.systemTemp.createTemp('patok-services-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
    appDir = Directory('${docsDir.path}/patok');
  });

  tearDown(() async {
    for (final name in [
      'library.json',
      'library.json.tmp',
      'waypoints.json',
      'waypoints.json.tmp',
      'measurements.json',
      'measurements.json.tmp',
    ]) {
      await _removeAny('${appDir.path}/$name');
    }
    for (final name in ['maps', 'dxf', 'thumbs']) {
      await _removeAny('${appDir.path}/$name');
    }
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await docsDir.delete(recursive: true);
  });

  group('MapLibrary.load per-entry tolerance (#1)', () {
    test('one corrupt map entry does not wipe the library', () async {
      final good1 = _testMap('good-1', name: 'Good one');
      final good2 = _testMap('good-2', name: 'Good two');
      final bad = good1.toJson()..['addedAt'] = 'not-a-date';
      final notAMap = 'oops';
      await appDir.create(recursive: true);
      await Directory('${appDir.path}/maps').create(recursive: true);
      for (final id in ['good-1', 'good-2']) {
        await File('${appDir.path}/maps/$id.pdf').writeAsString('pdf');
      }
      await File('${appDir.path}/library.json').writeAsString(jsonEncode({
        'maps': [good1.toJson(), bad, notAMap, good2.toJson()],
        'dxfImports': [],
      }));
      final lib = await MapLibrary.load();
      expect(lib.maps.map((m) => m.id), ['good-1', 'good-2']);
    });

    test('one corrupt dxf entry does not wipe the dxf imports', () async {
      final good = DxfImport(
        id: 'dxf-good',
        name: 'Good dxf',
        fileName: 'good.dxf',
        crs: DxfUtm(zone: 50),
        bounds: [116.0, -8.0, 117.0, -7.0],
        cadLayers: {'PIT': true},
      );
      final bad = good.toJson()..['bounds'] = 'nope';
      await appDir.create(recursive: true);
      await Directory('${appDir.path}/dxf').create(recursive: true);
      await File('${appDir.path}/dxf/dxf-good.json').writeAsString('{}');
      await File('${appDir.path}/library.json').writeAsString(jsonEncode({
        'maps': [],
        'dxfImports': [good.toJson(), bad],
      }));
      final lib = await MapLibrary.load();
      expect(lib.dxfImports.map((d) => d.id), ['dxf-good']);
    });

    test('a bad entry is not resurrected by the next save', () async {
      final good = _testMap('good-1');
      final bad = good.toJson()..['addedAt'] = 'not-a-date';
      await appDir.create(recursive: true);
      await Directory('${appDir.path}/maps').create(recursive: true);
      await File('${appDir.path}/maps/good-1.pdf').writeAsString('pdf');
      await File('${appDir.path}/library.json').writeAsString(jsonEncode({
        'maps': [good.toJson(), bad],
        'dxfImports': [],
      }));
      final lib = await MapLibrary.load();
      expect(lib.maps.length, 1);
      // Toggling a flag saves the library; the corrupt entry must not
      // come back, and the good one must survive.
      lib.maps.first.isFavorite = true;
      await lib.save();
      final reloaded = await MapLibrary.load();
      expect(reloaded.maps.map((m) => m.id), ['good-1']);
      expect(reloaded.maps.first.isFavorite, isTrue);
    });
  });

  group('atomic + serialized saves (#3, #4)', () {
    test('save leaves valid JSON and no temp file behind', () async {
      final lib = await MapLibrary.load();
      await lib.add(_testMap('m1'));
      final tmp = File('${appDir.path}/library.json.tmp');
      expect(await tmp.exists(), isFalse);
      final raw = jsonDecode(
        await File('${appDir.path}/library.json').readAsString(),
      );
      expect((raw['maps'] as List).length, 1);
    });

    test('two overlapping saves do not lose updates', () async {
      final lib = await MapLibrary.load();
      lib.maps.add(_testMap('a'));
      final s1 = lib.save();
      lib.maps.add(_testMap('b'));
      final s2 = lib.save();
      await Future.wait([s1, s2]);
      final raw = jsonDecode(
        await File('${appDir.path}/library.json').readAsString(),
      );
      expect(
        (raw['maps'] as List).map((m) => m['id']),
        containsAll(['a', 'b']),
      );
    });

    test('field-data saves are atomic and per-entry tolerant', () async {
      final store = await FieldDataStore.load();
      final wp = Waypoint(
        id: 'wp-1',
        name: 'WP1',
        longitude: 106.8,
        latitude: -6.2,
      );
      await store.saveWaypoints([wp]);
      expect(
        await File('${appDir.path}/waypoints.json.tmp').exists(),
        isFalse,
      );
      // One corrupt waypoint must not wipe the rest.
      final bad = wp.toJson()..['longitude'] = 'east';
      await File('${appDir.path}/waypoints.json').writeAsString(jsonEncode([
        wp.toJson(),
        bad,
      ]));
      final loaded = await store.waypoints();
      expect(loaded.map((w) => w.id), ['wp-1']);

      final m = Measurement(
        id: 'm-1',
        name: 'M1',
        points: [
          [106.8, -6.2],
          [106.9, -6.2],
        ],
        lengthMeters: 11000,
      );
      await store.saveMeasurements([m]);
      final badM = m.toJson()..['lengthMeters'] = 'far';
      await File('${appDir.path}/measurements.json').writeAsString(jsonEncode([
        m.toJson(),
        badM,
      ]));
      expect((await store.measurements()).map((x) => x.id), ['m-1']);
    });
  });

  group('remove() save-before-delete (#6)', () {
    test('a failing save keeps the entry and the PDF', () async {
      final map = _testMap('doomed');
      await appDir.create(recursive: true);
      await Directory('${appDir.path}/maps').create(recursive: true);
      await File('${appDir.path}/maps/doomed.pdf').writeAsString('pdf');
      await File('${appDir.path}/library.json').writeAsString(jsonEncode({
        'maps': [map.toJson()],
        'dxfImports': [],
      }));
      final lib = await MapLibrary.load();
      expect(lib.maps.length, 1);
      // Make every save fail: a directory where library.json should be.
      await File('${appDir.path}/library.json').delete();
      await Directory('${appDir.path}/library.json').create();
      await expectLater(lib.remove(map), throwsA(isA<FileSystemException>()));
      expect(lib.maps.map((m) => m.id), ['doomed']);
      expect(await File('${appDir.path}/maps/doomed.pdf').exists(), isTrue);
    });
  });

  group('ImportService (#13, #28)', () {
    test('importFile with no georeferencing leaves no orphan', () async {
      final lib = await MapLibrary.load();
      final service = ImportService(lib, RenderService());
      final src = File('${docsDir.path}/plain.pdf');
      await src.writeAsBytes(buildPdf([
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>',
      ]));
      await expectLater(
        service.importFile(src.path, (_) {}),
        throwsA(isA<StateError>()),
      );
      final mapsDir = Directory('${appDir.path}/maps');
      if (await mapsDir.exists()) {
        expect(await mapsDir.list().toList(), isEmpty);
      }
      expect(lib.maps, isEmpty);
    });

    test('importFile happy path copies, registers and thumbnails',
        () async {
      final lib = await MapLibrary.load();
      final service = ImportService(lib, RenderService());
      final src = File('${docsDir.path}/geo.pdf');
      await src.writeAsBytes(buildGeoPdf());
      final map = await service.importFile(src.path, (_) {});
      expect(map.pages.length, 1);
      expect(await File('${appDir.path}/maps/${map.id}.pdf').exists(), isTrue);
      expect(lib.maps.map((m) => m.id), contains(map.id));
      expect(
        await File('${appDir.path}/thumbs/${map.id}.png').exists(),
        isTrue,
      );
    });

    test('import with a broken page reports it, does not drop it silently',
        () async {
      final lib = await MapLibrary.load();
      final service = ImportService(lib, RenderService());
      final src = File('${docsDir.path}/one-bad-page.pdf');
      // Page 1 has collinear control points (all LPTS y=0): the affine
      // fit is singular. Page 2 is valid.
      await src.writeAsBytes(buildPdf([
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
      ]));
      final map = await service.importFile(src.path, (_) {});
      expect(map.pages.length, 1);
      expect(map.pages.single.pageIndex, 1);
      expect(map.skippedPages.length, 1);
      expect(map.skippedPages.single, contains('Page 1'));
      // The note survives the library round-trip.
      final reloaded = await MapLibrary.load();
      expect(reloaded.maps.single.skippedPages, map.skippedPages);
    });

    test('parseDxfFile runs on an isolate via compute', () async {
      final file = File('${docsDir.path}/line.dxf');
      await file.writeAsString(_dxfDoc(_dxfLine));
      final parsed = await compute(parseDxfFile, file.path);
      expect(parsed.doc.entities.length, 1);
      expect(parsed.fileName, 'line.dxf');
    });

    test('commitDxfImport projects off the UI thread and registers',
        () async {
      final lib = await MapLibrary.load();
      final service = ImportService(lib, RenderService());
      final file = File('${docsDir.path}/line2.dxf');
      await file.writeAsString(_dxfDoc(_dxfLine));
      final parsed = await compute(parseDxfFile, file.path);
      final imp = await service.commitDxfImport(
        parsed: parsed,
        crs: DxfUtm(zone: 50, southernHemisphere: true),
        name: 'Line',
        onProgress: (_) {},
      );
      expect(imp.bounds.length, 4);
      expect(imp.bounds[0], closeTo(117.0, 0.01));
      expect(imp.cadLayers.keys, contains('PIT'));
      expect(
        await File('${appDir.path}/dxf/${imp.id}.dxf').exists(),
        isTrue,
      );
      expect(
        await File('${appDir.path}/dxf/${imp.id}.json').exists(),
        isTrue,
      );
      expect(lib.dxfImports.map((d) => d.id), contains(imp.id));
    });

    test('a failed DXF commit leaves no orphan files', () async {
      final lib = await MapLibrary.load();
      final service = ImportService(lib, RenderService());
      final file = File('${docsDir.path}/line3.dxf');
      await file.writeAsString(_dxfDoc(_dxfLine));
      final parsed = await compute(parseDxfFile, file.path);
      // Make the library save fail after the copy + cache write.
      await File('${appDir.path}/library.json').writeAsString(jsonEncode({
        'maps': [],
        'dxfImports': [],
      }));
      await File('${appDir.path}/library.json').delete();
      await Directory('${appDir.path}/library.json').create();
      await expectLater(
        service.commitDxfImport(
          parsed: parsed,
          crs: DxfUtm(zone: 50, southernHemisphere: true),
          name: 'Line',
          onProgress: (_) {},
        ),
        throwsA(isA<FileSystemException>()),
      );
      final dxfDir = Directory('${appDir.path}/dxf');
      expect(await dxfDir.exists(), isTrue);
      expect(await dxfDir.list().toList(), isEmpty);
    });
  });

  group('RenderService PNG encode (o19)', () {
    test('renderPage returns a valid PNG', () async {
      final render = RenderService();
      final src = File('${docsDir.path}/render.pdf');
      await src.writeAsBytes(buildGeoPdf());
      final overlay = await render.renderPage(
        pdfPath: src.path,
        georef: PageGeoref(
          pageIndex: 0,
          pageWidthPt: 612,
          pageHeightPt: 792,
          rotation: 0,
          kind: GeorefKind.ogc,
          a: 1,
          b: 0,
          c: 0,
          d: 0,
          e: 1,
          f: 0,
          srcIsLonLat: true,
        ),
        dpi: 72,
      );
      expect(overlay.width, 612);
      expect(overlay.height, 792);
      // PNG magic bytes.
      expect(overlay.pngBytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });

  group('TrackRecorder (#14)', () {
    test('live points share one backing list, no copy per fix', () async {
      final controller = StreamController<Position>();
      final recorder = TrackRecorder(_FakeLocation(controller));
      await recorder.start();
      controller.add(_fix(106.8, -6.2));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final firstView = recorder.livePoints.value;
      expect(firstView.length, 1);
      controller.add(_fix(106.8001, -6.2));
      controller.add(_fix(106.8002, -6.2));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(recorder.pointCount.value, 3);
      // The first view sees the later fixes: same backing list, so no
      // per-fix copy was made (the old List.unmodifiable copy stayed at 1).
      expect(firstView.length, 3);
      expect(recorder.livePoints.value.length, 3);
      final m = await recorder.stop('track');
      expect(m, isNotNull);
      expect(m!.points.length, 3);
      expect(m.lengthMeters, greaterThan(0));
      await controller.close();
    });
  });

  group('WaypointAverager incremental mean (o20)', () {
    test('live average matches computeAverage', () async {
      final controller = StreamController<Position>();
      final averager = WaypointAverager(_FakeLocation(controller));
      await averager.start();
      final fixes = <Position>[];
      for (var i = 0; i < 60; i++) {
        final p = _fix(
          115.5 + (i % 2 == 0 ? 1e-5 : -1e-5),
          -2.1 + (i % 3 == 0 ? 1e-5 : 0),
        );
        fixes.add(p);
        controller.add(p);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(averager.fixCount.value, 60);
      final live = averager.average.value!;
      final ref = computeAverage(fixes);
      expect(live.longitude, closeTo(ref.longitude, 1e-9));
      expect(live.latitude, closeTo(ref.latitude, 1e-9));
      expect(live.fixCount, 60);
      // Tangent-plane identity vs geodesic RMS: agree far below GPS noise.
      expect(live.precisionMeters, closeTo(ref.precisionMeters, 0.001));
      final stopped = averager.stop();
      expect(stopped, isNotNull);
      expect(stopped!.longitude, closeTo(ref.longitude, 1e-9));
      expect(stopped.precisionMeters, closeTo(ref.precisionMeters, 1e-9));
      await controller.close();
    });

    test('identical fixes give precision 0, not a negative residue',
        () async {
      final controller = StreamController<Position>();
      final averager = WaypointAverager(_FakeLocation(controller));
      await averager.start();
      for (var i = 0; i < 10; i++) {
        controller.add(_fix(115.5, -2.1));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(averager.average.value!.precisionMeters, 0);
      await controller.close();
    });
  });

  group('SettingsService validation (m36)', () {
    test('out-of-range DPI and UTM zone are clamped', () async {
      SharedPreferences.setMockInitialValues({
        'renderDpi': 0.0,
        'lastDxfUtmZone': 0,
      });
      final settings = await SettingsService.load();
      expect(settings.renderDpi, 96);
      expect(settings.lastDxfUtmZone, 1);
      await settings.setRenderDpi(500);
      expect(settings.renderDpi, 300);
      await settings.setLastDxfUtm(61, true);
      expect(settings.lastDxfUtmZone, 60);
      await settings.setLastDxfUtm(-5, true);
      expect(settings.lastDxfUtmZone, 1);
    });
  });
}
