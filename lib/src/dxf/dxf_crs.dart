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

/// Suggests the UTM zone number for a longitude.
int utmZoneFor(double lon) => ((lon + 180) / 6).floor() + 1;

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
  DxfUtm({required this.zone, this.southernHemisphere = true});

  final int zone;
  final bool southernHemisphere;

  proj4.Projection? _proj;
  proj4.Projection get _p => _proj ??= proj4.Projection.parse(
        '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs'
        '${southernHemisphere ? ' +south' : ''}',
      );

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
    final scale = uLen / lLen;
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
    try {
      final list = jsonDecode(await _file.readAsString()) as List;
      return list
          .map((j) =>
              DxfCrs.fromJson(j as Map<String, dynamic>) as DxfLocalGrid)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<DxfLocalGrid> grids) async {
    await _file.writeAsString(
      jsonEncode(grids.map((g) => g.toJson()).toList()),
    );
  }
}
