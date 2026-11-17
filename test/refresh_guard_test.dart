import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/refresh_guard.dart';

void main() {
  group('RefreshGuard', () {
    test('sequential calls each run the body', () async {
      final guard = RefreshGuard();
      var runs = 0;
      await guard.run(() async => runs++);
      await guard.run(() async => runs++);
      expect(runs, 2);
    });

    test('concurrent calls share one run, then re-run once', () async {
      final guard = RefreshGuard();
      var runs = 0;
      var inFlight = 0;
      Future<void> body() async {
        runs++;
        inFlight++;
        await Future.delayed(const Duration(milliseconds: 20));
        inFlight--;
      }

      final first = guard.run(body);
      // Arrives while the first run is in flight.
      final second = guard.run(body);
      await Future.wait([first, second]);
      // First run + one re-run for the stale request.
      expect(runs, 2);
      expect(inFlight, 0);
      // A later call runs again normally.
      await guard.run(body);
      expect(runs, 3);
    });

    test('a call during the re-run triggers another re-run', () async {
      final guard = RefreshGuard();
      var runs = 0;
      Future<void> body() async {
        runs++;
        await Future.delayed(const Duration(milliseconds: 10));
      }

      final first = guard.run(body);
      await Future.delayed(const Duration(milliseconds: 5));
      final second = guard.run(body); // marks stale -> re-run
      await Future.delayed(const Duration(milliseconds: 15));
      final third = guard.run(body); // arrives during re-run
      await Future.wait([first, second, third]);
      expect(runs, 3);
    });

    test('a throwing body propagates and the guard resets', () async {
      final guard = RefreshGuard();
      var runs = 0;
      await expectLater(
        guard.run(() async {
          runs++;
          throw StateError('boom');
        }),
        throwsStateError,
      );
      // Guard is usable again after the failure.
      await guard.run(() async => runs++);
      expect(runs, 2);
    });
  });
}
