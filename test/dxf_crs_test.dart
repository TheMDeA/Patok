import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:patok/src/dxf/dxf_crs.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;

(double, double) _forwardUtm(int zone, bool south, double lon, double lat) {
  final proj = proj4.Projection.parse(
    '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs'
    '${south ? ' +south' : ''}',
  );
  final p = proj4.Projection.WGS84.transform(
    proj,
    proj4.Point(x: lon, y: lat),
  );
  return (p.x, p.y);
}

void main() {
  group('DxfUtm', () {
    test('inverse round-trips through proj4', () {
      const lon = 115.5, lat = -2.15;
      final (e, n) = _forwardUtm(50, true, lon, lat);
      // Sanity: plausible UTM 50S values.
      expect(e, inInclusiveRange(100000.0, 900000.0));
      expect(n, inInclusiveRange(9000000.0, 10000000.0));
      final (rlon, rlat) =
          DxfUtm(zone: 50, southernHemisphere: true).toLonLat(e, n);
      expect(rlon, closeTo(lon, 1e-9));
      expect(rlat, closeTo(lat, 1e-9));
    });

    test('northern hemisphere', () {
      const lon = -122.0, lat = 37.5;
      final (e, n) = _forwardUtm(10, false, lon, lat);
      final (rlon, rlat) =
          DxfUtm(zone: 10, southernHemisphere: false).toLonLat(e, n);
      expect(rlon, closeTo(lon, 1e-9));
      expect(rlat, closeTo(lat, 1e-9));
    });

    test('json round-trip', () {
      final crs = DxfUtm(zone: 50, southernHemisphere: true);
      final back = DxfCrs.fromJson(crs.toJson()) as DxfUtm;
      expect(back.zone, 50);
      expect(back.southernHemisphere, isTrue);
    });
  });

  group('utmZoneFor', () {
    test('suggests zones', () {
      expect(utmZoneFor(115.5), 50);
      expect(utmZoneFor(-122.0), 10);
      expect(utmZoneFor(0.0), 31);
    });
  });

  group('DxfLocalGrid', () {
    // Two real-world reference points (Kalimantan, UTM 50S).
    const lonA = 115.48;
    const latA = -2.13;
    const lonB = 115.53;
    const latB = -2.18;

    /// Builds a grid whose local coords are the UTM coords rotated by
    /// [rotDeg] and shifted, so the solver must recover the transform.
    DxfLocalGrid rotatedGrid(double rotDeg) {
      final (uax, uay) = _forwardUtm(50, true, lonA, latA);
      final (ubx, uby) = _forwardUtm(50, true, lonB, latB);
      final rad = -rotDeg * math.pi / 180; // local = inverse-rotated UTM
      final c = math.cos(rad), s = math.sin(rad);
      double lx(double ux, double uy) => 1000 + c * (ux - uax) + s * (uy - uay);
      double ly(double ux, double uy) => 2000 - s * (ux - uax) + c * (uy - uay);
      return DxfLocalGrid(
        name: 'test',
        zone: 50,
        southernHemisphere: true,
        e1: lx(uax, uay),
        n1: ly(uax, uay),
        lon1: lonA,
        lat1: latA,
        e2: lx(ubx, uby),
        n2: ly(ubx, uby),
        lon2: lonB,
        lat2: latB,
      );
    }

    test('recovers rotation and scale', () {
      final grid = rotatedGrid(15);
      // local = R(+15°)·UTM, so the local→UTM rotation is −15°.
      expect(grid.rotationDeg, closeTo(-15.0, 1e-6));
      expect(grid.scale, closeTo(1.0, 1e-9));
    });

    test('reference points map back to themselves', () {
      final grid = rotatedGrid(15);
      final (rLonA, rLatA) = grid.toLonLat(grid.e1, grid.n1);
      final (rLonB, rLatB) = grid.toLonLat(grid.e2, grid.n2);
      expect(rLonA, closeTo(lonA, 1e-9));
      expect(rLatA, closeTo(latA, 1e-9));
      expect(rLonB, closeTo(lonB, 1e-9));
      expect(rLatB, closeTo(latB, 1e-9));
    });

    test('midpoint maps to the UTM midpoint', () {
      final grid = rotatedGrid(-30);
      final midE = (grid.e1 + grid.e2) / 2;
      final midN = (grid.n1 + grid.n2) / 2;
      final (rlon, rlat) = grid.toLonLat(midE, midN);
      // Independent expectation: midpoint in UTM, inverse-projected.
      final (uax, uay) = _forwardUtm(50, true, lonA, latA);
      final (ubx, uby) = _forwardUtm(50, true, lonB, latB);
      final (eLon, eLat) = DxfUtm(zone: 50, southernHemisphere: true)
          .toLonLat((uax + ubx) / 2, (uay + uby) / 2);
      expect(rlon, closeTo(eLon, 1e-9));
      expect(rlat, closeTo(eLat, 1e-9));
    });

    test('identity grid (local == UTM) works', () {
      final (uax, uay) = _forwardUtm(50, true, lonA, latA);
      final (ubx, uby) = _forwardUtm(50, true, lonB, latB);
      final grid = DxfLocalGrid(
        name: 'identity',
        zone: 50,
        southernHemisphere: true,
        e1: uax,
        n1: uay,
        lon1: lonA,
        lat1: latA,
        e2: ubx,
        n2: uby,
        lon2: lonB,
        lat2: latB,
      );
      expect(grid.rotationDeg, closeTo(0.0, 1e-6));
      expect(grid.scale, closeTo(1.0, 1e-9));
      final (rlon, rlat) = grid.toLonLat(uax, uay);
      expect(rlon, closeTo(lonA, 1e-9));
      expect(rlat, closeTo(latA, 1e-9));
    });

    test('too-close reference points throw', () {
      expect(
        () => DxfLocalGrid(
          name: 'bad',
          zone: 50,
          e1: 1000,
          n1: 2000,
          lon1: lonA,
          lat1: latA,
          e2: 1000.0000001,
          n2: 2000.0000001,
          lon2: lonB,
          lat2: latB,
        ),
        throwsStateError,
      );
    });

    test('json round-trip', () {
      final grid = rotatedGrid(15);
      final back =
          DxfCrs.fromJson(grid.toJson()) as DxfLocalGrid;
      expect(back.name, 'test');
      expect(back.zone, 50);
      expect(back.e1, grid.e1);
      final (rlon, rlat) = back.toLonLat(back.e1, back.n1);
      expect(rlon, closeTo(lonA, 1e-9));
      expect(rlat, closeTo(latA, 1e-9));
    });
  });

  group('DxfLocalGridStore', () {
    test('saves and loads grids', () async {
      final dir = await Directory.systemTemp.createTemp('dxf_crs');
      try {
        final store = await DxfLocalGridStore.load(dir);
        expect(await store.all(), isEmpty);
        final grid = DxfLocalGrid(
          name: 'mine',
          zone: 50,
          e1: 1000,
          n1: 2000,
          lon1: 115.48,
          lat1: -2.13,
          e2: 6000,
          n2: 7000,
          lon2: 115.53,
          lat2: -2.18,
        );
        await store.saveAll([grid]);
        final loaded = await DxfLocalGridStore.load(dir).then((s) => s.all());
        expect(loaded, hasLength(1));
        expect(loaded.single.name, 'mine');
        expect(loaded.single.rotationDeg, closeTo(grid.rotationDeg, 1e-9));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
