import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:patok/src/waypoint_averaging.dart';

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

void main() {
  group('computeAverage', () {
    test('mean of identical fixes is the fix, precision 0', () {
      final r = computeAverage(
          List.generate(10, (_) => _fix(115.5, -2.1)));
      expect(r.longitude, closeTo(115.5, 1e-9));
      expect(r.latitude, closeTo(-2.1, 1e-9));
      expect(r.precisionMeters, closeTo(0, 1e-6));
      expect(r.fixCount, 10);
    });

    test('averages a noisy cloud toward center', () {
      final fixes = [
        _fix(115.5, -2.1),
        _fix(115.5001, -2.1),
        _fix(115.4999, -2.1),
        _fix(115.5, -2.1001),
        _fix(115.5, -2.0999),
      ];
      final r = computeAverage(fixes);
      expect(r.longitude, closeTo(115.5, 1e-9));
      expect(r.latitude, closeTo(-2.1, 1e-9));
      // ~11m offsets -> RMS spread around ~7m.
      expect(r.precisionMeters, greaterThan(3));
      expect(r.precisionMeters, lessThan(15));
    });

    test('more fixes, same cloud -> same mean', () {
      final cloud =
          List.generate(60, (i) => _fix(115.5 + (i % 2 == 0 ? 1e-5 : -1e-5), -2.1));
      final r = computeAverage(cloud);
      expect(r.longitude, closeTo(115.5, 1e-9));
      expect(r.fixCount, 60);
    });
  });
}
