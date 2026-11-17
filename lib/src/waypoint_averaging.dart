import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'services.dart';

/// Result of averaging GPS fixes while stationary.
class AverageResult {
  const AverageResult({
    required this.longitude,
    required this.latitude,
    required this.fixCount,
    required this.precisionMeters,
  });
  final double longitude;
  final double latitude;
  final int fixCount;

  /// RMS spread of the fixes around the mean — the "±" figure.
  final double precisionMeters;
}

/// Pure averaging math: mean position + RMS spread. Testable without GPS.
AverageResult computeAverage(List<Position> fixes) {
  var lonSum = 0.0;
  var latSum = 0.0;
  for (final p in fixes) {
    lonSum += p.longitude;
    latSum += p.latitude;
  }
  final lon = lonSum / fixes.length;
  final lat = latSum / fixes.length;
  var sqSum = 0.0;
  for (final p in fixes) {
    final d = Geolocator.distanceBetween(lat, lon, p.latitude, p.longitude);
    sqSum += d * d;
  }
  return AverageResult(
    longitude: lon,
    latitude: lat,
    fixCount: fixes.length,
    precisionMeters: math.sqrt(sqSum / fixes.length),
  );
}

/// Collects 1Hz GPS fixes while the user stands still and maintains a
/// running average. Uses a time-based stream (no distance filter) — the
/// app's main stream goes quiet when stationary.
class WaypointAverager {
  WaypointAverager(this._locationService);
  final LocationService _locationService;

  final ValueNotifier<int> fixCount = ValueNotifier(0);
  final ValueNotifier<AverageResult?> average = ValueNotifier(null);

  StreamSubscription<Position>? _sub;
  final List<Position> _fixes = [];

  // Incremental accumulators: the old code recomputed the mean and RMS
  // spread from scratch over all fixes on every fix — O(n^2)
  // distanceBetween calls over a session. The mean is a running sum
  // (O(1) per fix). The RMS spread uses the parallel-axis identity
  // with the first fix as origin: sum of squared distances to the mean
  // = sum of squared distances to the origin - n * (distance from the
  // mean to the origin)^2. Exact in the local tangent plane; for a
  // stationary cloud (tens of meters) the geodesic error is ~1e-11
  // relative, far below GPS noise. stop() still returns the exact
  // computeAverage() of the stored fixes.
  double _lonSum = 0;
  double _latSum = 0;
  double _sqSumOrigin = 0;
  double? _originLon;
  double? _originLat;

  bool get isRunning => _sub != null;

  Future<void> start() async {
    if (isRunning) return;
    if (!await _locationService.ensurePermission()) {
      throw StateError('Location permission denied');
    }
    _fixes.clear();
    _lonSum = 0;
    _latSum = 0;
    _sqSumOrigin = 0;
    _originLon = null;
    _originLat = null;
    fixCount.value = 0;
    average.value = null;
    _sub = _locationService.rawPositionStream().listen(
      (p) {
        _fixes.add(p);
        final n = _fixes.length;
        _lonSum += p.longitude;
        _latSum += p.latitude;
        _originLon ??= p.longitude;
        _originLat ??= p.latitude;
        final dOrigin = Geolocator.distanceBetween(
          _originLat!,
          _originLon!,
          p.latitude,
          p.longitude,
        );
        _sqSumOrigin += dOrigin * dOrigin;
        fixCount.value = n;
        average.value = _currentAverage();
      },
      onError: (_) {
        // The platform stream died (e.g. permission revoked): stop
        // collecting, but keep the fixes so stop() can still average
        // what was collected.
        _sub?.cancel();
        _sub = null;
      },
    );
  }

  AverageResult _currentAverage() {
    final n = _fixes.length;
    final lon = _lonSum / n;
    final lat = _latSum / n;
    final dMeanOrigin = Geolocator.distanceBetween(
      _originLat!,
      _originLon!,
      lat,
      lon,
    );
    // Clamp: float residue can make this a hair negative when all
    // fixes are identical.
    final meanSq = math.max(
      0.0,
      (_sqSumOrigin - n * dMeanOrigin * dMeanOrigin) / n,
    );
    return AverageResult(
      longitude: lon,
      latitude: lat,
      fixCount: n,
      precisionMeters: math.sqrt(meanSq),
    );
  }

  /// Stops and returns the averaged result, or null when too few fixes.
  AverageResult? stop({int minFixes = 10}) {
    _sub?.cancel();
    _sub = null;
    if (_fixes.length < minFixes) return null;
    return computeAverage(_fixes);
  }

  void cancel() {
    _sub?.cancel();
    _sub = null;
    _fixes.clear();
    _lonSum = 0;
    _latSum = 0;
    _sqSumOrigin = 0;
    _originLon = null;
    _originLat = null;
    fixCount.value = 0;
    average.value = null;
  }

  void dispose() {
    _sub?.cancel();
    fixCount.dispose();
    average.dispose();
  }
}
