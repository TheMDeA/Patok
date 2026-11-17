import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:patok/src/update_service.dart';

/// A fake HTTP client returning a canned [http.StreamedResponse].
class _FakeClient extends http.BaseClient {
  _FakeClient(this.response);
  final http.StreamedResponse response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
}

/// Minimal fake APK bytes: ZIP local header + filler + end-of-central-
/// directory record. With [truncated], the EOCD record is omitted, so the
/// file looks like a download that stopped halfway.
Uint8List _fakeApk({bool truncated = false}) {
  final buf = <int>[0x50, 0x4B, 0x03, 0x04]; // PK\x03\x04
  buf.addAll(List.filled(100, 0));
  if (!truncated) {
    buf.addAll([0x50, 0x4B, 0x05, 0x06]); // PK\x05\x06
    buf.addAll(List.filled(18, 0)); // EOCD record
  }
  return Uint8List.fromList(buf);
}

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

group('download completion, cancellation and cache (#7, #21)', () {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory dir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('patok_dl_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getTemporaryDirectory') return dir.path;
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  test('a truncated stream throws and never becomes the cached APK',
      () async {
    // MockClient reports content-length from the body, so a lying
    // content-length needs a hand-built StreamedResponse.
    final bytes = List.generate(40, (i) => i % 256);
    final client = _FakeClient(
      http.StreamedResponse(Stream.value(bytes), 200, contentLength: 100),
    );
    await expectLater(
      downloadApk('https://example.com/app.apk', '9.9.9',
          onProgress: (_) {}, client: client),
      throwsA(isA<HttpException>()),
    );
    // The .part file stays (resumable), but no .apk is ever created.
    expect(await File('${dir.path}/patok-9.9.9.apk').exists(), isFalse);
    expect(await File('${dir.path}/patok-9.9.9.apk.part').exists(), isTrue);
  });

  test('cancelling between chunks throws DownloadCancelled', () async {
    final controller = StreamController<List<int>>();
    final client = _FakeClient(
      http.StreamedResponse(controller.stream, 200, contentLength: 1000),
    );
    var cancelled = false;
    final future = downloadApk('https://example.com/app.apk', '9.9.9',
        onProgress: (_) {}, isCancelled: () => cancelled, client: client);
    controller.add(List.filled(100, 0));
    await Future<void>.delayed(Duration.zero);
    cancelled = true;
    controller.add(List.filled(100, 0));
    await controller.close();
    await expectLater(future, throwsA(isA<DownloadCancelled>()));
    // The partial download is kept for a later resume.
    expect(await File('${dir.path}/patok-9.9.9.apk.part').exists(), isTrue);
  });

  test('no file is not cached', () async {
    expect(await isApkCached('9.9.9'), isFalse);
  });

  test('a valid APK is cached', () async {
    await File('${dir.path}/patok-9.9.9.apk').writeAsBytes(_fakeApk());
    expect(await isApkCached('9.9.9'), isTrue);
  });

  test('a truncated APK is not cached', () async {
    await File('${dir.path}/patok-9.9.9.apk')
        .writeAsBytes(_fakeApk(truncated: true));
    expect(await isApkCached('9.9.9'), isFalse);
  });

  test('a non-ZIP file is not cached', () async {
    await File('${dir.path}/patok-9.9.9.apk')
        .writeAsString('not an apk at all, just text');
    expect(await isApkCached('9.9.9'), isFalse);
  });
});
}
