import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:patok/src/update_service.dart';

void main() {
  group('isNewerVersion', () {
    test('detects newer patch/minor/major', () {
      expect(isNewerVersion('1.0.3', '1.0.2'), isTrue);
      expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('numeric, not lexicographic: 1.0.10 > 1.0.9', () {
      expect(isNewerVersion('1.0.10', '1.0.9'), isTrue);
      expect(isNewerVersion('1.0.9', '1.0.10'), isFalse);
    });

    test('equal or older is not newer', () {
      expect(isNewerVersion('1.0.2', '1.0.2'), isFalse);
      expect(isNewerVersion('1.0.1', '1.0.2'), isFalse);
    });

    test('ignores build metadata', () {
      expect(isNewerVersion('1.0.3', '1.0.2+3'), isTrue);
      expect(isNewerVersion('1.0.2+4', '1.0.2+3'), isFalse);
    });

    test('handles v prefix and uneven segments', () {
      expect(isNewerVersion('v1.1', '1.0.9'), isTrue);
      expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    });
  });

group('downloadApk resume', () {
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('patok_dl_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getTemporaryDirectory') return dir.path;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('fresh download writes the full file', () async {
    final bytes = List.generate(1000, (i) => i % 256);
    final client = MockClient((req) async {
      expect(req.headers['Range'], isNull);
      return http.Response.bytes(bytes, 200,
          headers: {'content-length': '1000'});
    });
    var lastFraction = -1.0;
    await downloadApk('https://example.com/app.apk', '9.9.9',
        onProgress: (p) => lastFraction = p.fraction, client: client);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/patok-9.9.9.apk');
    expect(await file.exists(), isTrue);
    expect(await file.length(), 1000);
    expect(lastFraction, closeTo(1.0, 0.001));
  });

  test('resumes from an existing .part file with Range', () async {
    final dir = await getTemporaryDirectory();
    final part = File('${dir.path}/patok-9.9.9.apk.part');
    final firstHalf = List.generate(400, (i) => i % 256);
    await part.writeAsBytes(firstHalf);
    final secondHalf = List.generate(600, (i) => (i + 400) % 256);
    var sawRange = false;
    final client = MockClient((req) async {
      if (req.headers['Range'] == 'bytes=400-') sawRange = true;
      return http.Response.bytes(secondHalf, 206, headers: {
        'content-range': 'bytes 400-999/1000',
        'content-length': '600',
      });
    });
    await downloadApk('https://example.com/app.apk', '9.9.9',
        onProgress: (_) {}, client: client);
    expect(sawRange, isTrue);
    final file = File('${dir.path}/patok-9.9.9.apk');
    final all = await file.readAsBytes();
    expect(all.length, 1000);
    expect(all.sublist(0, 400), firstHalf);
    expect(all.sublist(400), secondHalf);
  });

  test('restarts when the server ignores Range', () async {
    final dir = await getTemporaryDirectory();
    final part = File('${dir.path}/patok-9.9.9.apk.part');
    await part.writeAsBytes(List.generate(400, (i) => i % 256));
    final full = List.generate(1000, (i) => (i + 7) % 256);
    final client = MockClient((req) async {
      return http.Response.bytes(full, 200,
          headers: {'content-length': '1000'});
    });
    await downloadApk('https://example.com/app.apk', '9.9.9',
        onProgress: (_) {}, client: client);
    final file = File('${dir.path}/patok-9.9.9.apk');
    expect(await file.readAsBytes(), full);
  });
});
}
