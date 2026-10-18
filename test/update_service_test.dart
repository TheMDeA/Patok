import 'package:flutter_test/flutter_test.dart';
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
}
