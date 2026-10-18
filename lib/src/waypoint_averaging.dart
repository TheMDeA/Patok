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
  bool get isRunning => _sub != null;

  Future<void> start() async {
    if (isRunning) return;
    if (!await _locationService.ensurePermission()) {
      throw StateError('Location permission denied');
    }
    _fixes.clear();
    fixCount.value = 0;
    average.value = null;
    _sub = _locationService.rawPositionStream().listen((p) {
      _fixes.add(p);
      fixCount.value = _fixes.length;
      average.value = computeAverage(_fixes);
    });
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
    fixCount.value = 0;
    average.value = null;
  }

  void dispose() {
    _sub?.cancel();
    fixCount.dispose();
    average.dispose();
  }
}
