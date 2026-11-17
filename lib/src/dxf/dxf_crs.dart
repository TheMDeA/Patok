/// Coordinate references for DXF native coordinates (easting/northing).
///
/// Mine DXF files come in two flavors:
/// - [DxfUtm]: plain UTM (zone picked at import).
/// - [DxfLocalGrid]: a mine local grid, defined once by two reference points
///   (local E/N <-> real-world lon/lat) and solved as a similarity
///   transform into UTM. Saved by name and reused across imports.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:proj4dart/proj4dart.dart' as proj4;

/// Suggests the UTM zone number for a longitude (clamped to 1..60).
int utmZoneFor(double lon) {
  final zone = ((lon + 180) / 6).floor() + 1;
  return zone.clamp(1, 60);
}

/// A coordinate reference mapping DXF (easting, northing) to lon/lat.
sealed class DxfCrs {
  const DxfCrs();

  /// Converts a native (easting, northing) pair to (longitude, latitude).
  (double lon, double lat) toLonLat(double easting, double northing);

  Map<String, dynamic> toJson();

  static DxfCrs fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'utm':
        return DxfUtm(
          zone: (j['zone'] as num).toInt(),
          southernHemisphere: j['southernHemisphere'] as bool? ?? true,
        );
      case 'local':
        return DxfLocalGrid(
          name: j['name'] as String,
          zone: (j['zone'] as num).toInt(),
          southernHemisphere: j['southernHemisphere'] as bool? ?? true,
          e1: (j['e1'] as num).toDouble(),
          n1: (j['n1'] as num).toDouble(),
          lon1: (j['lon1'] as num).toDouble(),
          lat1: (j['lat1'] as num).toDouble(),
          e2: (j['e2'] as num).toDouble(),
          n2: (j['n2'] as num).toDouble(),
          lon2: (j['lon2'] as num).toDouble(),
          lat2: (j['lat2'] as num).toDouble(),
        );
      default:
        throw ArgumentError('Unknown DXF CRS type: ${j['type']}');
    }
  }
}

/// Plain UTM reference.
class DxfUtm extends DxfCrs {
  DxfUtm({required this.zone, this.southernHemisphere = true}) {
    if (zone < 1 || zone > 60) {
      throw ArgumentError.value(zone, 'zone', 'UTM zone must be 1..60');
    }
  }

  final int zone;
  final bool southernHemisphere;

  // Projections are parsed once per zone/hemisphere and shared: grid
  // previews re-solve on every keystroke and must not re-parse each time.
  static final _projCache = <String, proj4.Projection>{};
  proj4.Projection get _p {
    final key = '$zone|${southernHemisphere ? 'S' : 'N'}';
    return _projCache.putIfAbsent(
      key,
      () => proj4.Projection.parse(
        '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs'
        '${southernHemisphere ? ' +south' : ''}',
      ),
    );
  }

  @override
  (double lon, double lat) toLonLat(double easting, double northing) {
    final p = _p.transform(
      proj4.Projection.WGS84,
      proj4.Point(x: easting, y: northing),
    );
    return (p.x, p.y);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'utm',
        'zone': zone,
        'southernHemisphere': southernHemisphere,
      };
}

/// A named mine local grid, solved from two reference points as a
/// similarity transform (scale + rotation + translation) into UTM.
///
/// Throws [StateError] at construction when the reference points are too
/// close together to solve reliably.
class DxfLocalGrid extends DxfCrs {
  DxfLocalGrid({
    required this.name,
    required this.zone,
    this.southernHemisphere = true,
    required this.e1,
    required this.n1,
    required this.lon1,
    required this.lat1,
    required this.e2,
    required this.n2,
    required this.lon2,
    required this.lat2,
  })  : _utm = DxfUtm(zone: zone, southernHemisphere: southernHemisphere),
        _sol = _solve(e1, n1, e2, n2, zone, southernHemisphere, lon1, lat1,
            lon2, lat2);

  final String name;
  final int zone;
  final bool southernHemisphere;

  /// Reference point A: local coords + real position.
  final double e1, n1, lon1, lat1;

  /// Reference point B: local coords + real position.
  final double e2, n2, lon2, lat2;

  final DxfUtm _utm;
  final _Solution _sol;

  /// Solved scale (local units per UTM meter; ~1 for real mine grids).
  double get scale => _sol.scale;

  /// Solved grid-north rotation in degrees (counter-clockwise positive).
  double get rotationDeg => _sol.theta * 180 / math.pi;

  @override
  (double lon, double lat) toLonLat(double easting, double northing) {
    final c = math.cos(_sol.theta);
    final s = math.sin(_sol.theta);
    final ux = _sol.tx + _sol.scale * (c * easting - s * northing);
    final uy = _sol.ty + _sol.scale * (s * easting + c * northing);
    return _utm.toLonLat(ux, uy);
  }

  static _Solution _solve(
    double e1,
    double n1,
    double e2,
    double n2,
    int zone,
    bool southern,
    double lon1,
    double lat1,
    double lon2,
    double lat2,
  ) {
    final lvx = e2 - e1;
    final lvy = n2 - n1;
    final lLen = math.sqrt(lvx * lvx + lvy * lvy);
    if (lLen < 1e-6) {
      throw StateError(
        'Reference points are too close together to solve the grid transform.',
      );
    }
    final utm = DxfUtm(zone: zone, southernHemisphere: southern);
    // Forward project the reference lon/lats into UTM.
    final u1 = _toUtm(utm, lon1, lat1);
    final u2 = _toUtm(utm, lon2, lat2);
    final uvx = u2.$1 - u1.$1;
    final uvy = u2.$2 - u1.$2;
    final uLen = math.sqrt(uvx * uvx + uvy * uvy);
    // The local distance alone is not enough: two reference points at
    // (nearly) the same real-world spot give a ~0 scale and collapse the
    // whole drawing to a point.
    if (!uLen.isFinite || uLen < 1.0) {
      throw StateError(
        'Reference points are (nearly) the same real-world location — '
        'pick two distinct points.',
      );
    }
    final scale = uLen / lLen;
    // Mine local grids are metres or feet (~1 or ~0.3); a scale outside
    // this band means a typo in a reference point, not a real grid.
    if (!scale.isFinite || scale < 0.01 || scale > 100) {
      throw StateError(
        'Solved scale ${scale.toStringAsFixed(4)} is implausible — '
        'check the reference points.',
      );
    }
    final theta = math.atan2(uvy, uvx) - math.atan2(lvy, lvx);
    final c = math.cos(theta);
    final s = math.sin(theta);
    final tx = u1.$1 - scale * (c * e1 - s * n1);
    final ty = u1.$2 - scale * (s * e1 + c * n1);
    return _Solution(scale: scale, theta: theta, tx: tx, ty: ty);
  }

  static (double, double) _toUtm(DxfUtm utm, double lon, double lat) {
    final p = proj4.Projection.WGS84.transform(
      utm._p,
      proj4.Point(x: lon, y: lat),
    );
    return (p.x, p.y);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'local',
        'name': name,
        'zone': zone,
        'southernHemisphere': southernHemisphere,
        'e1': e1,
        'n1': n1,
        'lon1': lon1,
        'lat1': lat1,
        'e2': e2,
        'n2': n2,
        'lon2': lon2,
        'lat2': lat2,
      };
}

class _Solution {
  const _Solution({
    required this.scale,
    required this.theta,
    required this.tx,
    required this.ty,
  });
  final double scale;
  final double theta;
  final double tx;
  final double ty;
}

/// Named local grids persisted to a JSON file. Wired through [AppScope]
/// in batch 3; takes any directory in tests.
class DxfLocalGridStore {
  DxfLocalGridStore._(this._file);
  final File _file;

  static Future<DxfLocalGridStore> load(Directory dir) async =>
      DxfLocalGridStore._(File('${dir.path}/dxf_local_grids.json'));

  Future<List<DxfLocalGrid>> all() async {
    if (!await _file.exists()) return [];
    List decoded;
    try {
      decoded = jsonDecode(await _file.readAsString()) as List;
    } catch (_) {
      return [];
    }
    // One corrupt entry must not wipe the rest of the saved grids.
    final grids = <DxfLocalGrid>[];
    for (final j in decoded) {
      try {
        grids.add(DxfCrs.fromJson(j as Map<String, dynamic>) as DxfLocalGrid);
      } catch (_) {
        // Skip the bad entry; the rest still load.
      }
    }
    return grids;
  }

  Future<void> saveAll(List<DxfLocalGrid> grids) async {
    // Atomic write: a crash mid-write must not leave a truncated file
    // behind (which the next load would read as "no grids at all").
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(grids.map((g) => g.toJson()).toList()),
    );
    await tmp.rename(_file.path);
  }
}
