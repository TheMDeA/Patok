import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/ui/library_screen.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('patok-undo-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File makeFile(String name, [String contents = 'x']) {
    final f = File('${dir.path}/$name')..writeAsStringSync(contents);
    return f;
  }

  group('moveAsideForUndo', () {
    test('moves existing files to .undo and returns the backups', () async {
      final a = makeFile('a.pdf');
      final b = makeFile('b.json');
      final moved = await moveAsideForUndo([a.path, b.path]);
      expect(moved, isNotNull);
      expect(moved!.map((f) => f.path),
          ['${a.path}.undo', '${b.path}.undo']);
      expect(await a.exists(), isFalse);
      expect(await b.exists(), isFalse);
      expect(await File('${a.path}.undo').exists(), isTrue);
      expect(await File('${b.path}.undo').exists(), isTrue);
    });

    test('skips missing files and returns an empty list', () async {
      final moved = await moveAsideForUndo(
          ['${dir.path}/nope.pdf', '${dir.path}/nope.json']);
      expect(moved, isNotNull);
      expect(moved, isEmpty);
    });

    test('returns null and puts back moved files when a later move fails',
        () async {
      final a = makeFile('a.pdf');
      final b = makeFile('b.json');
      // A directory at the .undo path makes b's rename fail.
      await Directory('${b.path}.undo').create();
      final moved = await moveAsideForUndo([a.path, b.path]);
      expect(moved, isNull);
      // a was already moved aside; it must be back at its original path.
      expect(await a.exists(), isTrue);
      expect(await File('${a.path}.undo').exists(), isFalse);
      // b was never touched.
      expect(await b.exists(), isTrue);
    });
  });

  group('restoreFromUndo', () {
    test('moves backups back to their original paths', () async {
      final a = makeFile('a.pdf');
      final moved = await moveAsideForUndo([a.path]);
      expect(moved, isNotNull);
      expect(await restoreFromUndo(moved!), isTrue);
      expect(await a.exists(), isTrue);
      expect(await File('${a.path}.undo').exists(), isFalse);
    });

    test('returns false when a restore fails, keeps the rest restored',
        () async {
      final a = makeFile('a.pdf');
      final b = makeFile('b.json');
      final moved = await moveAsideForUndo([a.path, b.path]);
      expect(moved, isNotNull);
      // Block a's way back with a directory at the original path.
      await Directory(a.path).create();
      expect(await restoreFromUndo(moved!), isFalse);
      // b was restored; a is still at its .undo path.
      expect(await b.exists(), isTrue);
      expect(await File('${a.path}.undo').exists(), isTrue);
    });
  });
}
