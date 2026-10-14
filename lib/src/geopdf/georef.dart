import 'dart:math' as math;

import 'package:proj4dart/proj4dart.dart' as proj4;

import '../models.dart';
import 'pdf_model.dart';
import 'pdf_parser.dart';

/// Fits an affine transform `u = a*x + b*y + c`, `v = d*x + e*y + f`
/// through point pairs using least squares (min 3 non-collinear points).
///
/// Returns [a, b, c, d, e, f].
List<double> fitAffine(
    List<math.Point<double>> src, List<math.Point<double>> dst) {
  if (src.length != dst.length || src.length < 3) {
    throw ArgumentError('Need at least 3 point pairs');
  }
  // Normal equations: (M^T M) p = M^T q, with M rows [x, y, 1].
  double sxx = 0, sxy = 0, sx = 0, syy = 0, sy = 0, n = 0;
  double sxu = 0, syu = 0, su = 0; // for u
  double sxv = 0, syv = 0, sv = 0; // for v
  for (var i = 0; i < src.length; i++) {
    final x = src[i].x, y = src[i].y;
    final u = dst[i].x, v = dst[i].y;
    sxx += x * x;
    sxy += x * y;
    sx += x;
    syy += y * y;
    sy += y;
    n += 1;
    sxu += x * u;
    syu += y * u;
    su += u;
    sxv += x * v;
    syv += y * v;
    sv += v;
  }
  final abc = _solve3(
    [sxx, sxy, sx, sxy, syy, sy, sx, sy, n],
    [sxu, syu, su],
  );
  final def = _solve3(
    [sxx, sxy, sx, sxy, syy, sy, sx, sy, n],
    [sxv, syv, sv],
  );
  return [...abc, ...def];
}

/// Solves a 3x3 linear system given row-major [m] and [rhs].
List<double> _solve3(List<double> m, List<double> rhs) {
  // Gaussian elimination with partial pivoting.
  final a = [
    [m[0], m[1], m[2], rhs[0]],
    [m[3], m[4], m[5], rhs[1]],
    [m[6], m[7], m[8], rhs[2]],
  ];
  for (var col = 0; col < 3; col++) {
    var pivot = col;
    for (var row = col + 1; row < 3; row++) {
      if (a[row][col].abs() > a[pivot][col].abs()) pivot = row;
    }
    if (a[pivot][col].abs() < 1e-12) {
      throw ArgumentError('Singular system: control points are collinear');
    }
    final tmp = a[col];
    a[col] = a[pivot];
    a[pivot] = tmp;
    for (var row = col + 1; row < 3; row++) {
      final f = a[row][col] / a[col][col];
      for (var k = col; k < 4; k++) {
        a[row][k] -= f * a[col][k];
      }
    }
  }
  final x = List<double>.filled(3, 0);
  for (var row = 2; row >= 0; row--) {
    var s = a[row][3];
    for (var k = row + 1; k < 3; k++) {
      s -= a[row][k] * x[k];
    }
    x[row] = s / a[row][row];
  }
  return x;
}

List<double> _numbers(PdfObject? obj) {
  final arr = obj is PdfArray ? obj : null;
  if (arr == null) throw PdfParseException('Expected number array');
  return arr.numbers;
}

List<math.Point<double>> _pairs(List<double> nums) {
  if (nums.length % 2 != 0) {
    throw PdfParseException('Odd number of coordinates');
  }
  return [
    for (var i = 0; i < nums.length; i += 2)
      math.Point(nums[i], nums[i + 1]),
  ];
}

/// True when LPTS look like viewport-normalized coordinates (~0..1,
/// Avenza-style) rather than page points (hundreds of points).
bool _looksNormalized(List<math.Point<double>> lpts) {
  var m = 0.0;
  for (final p in lpts) {
    m = math.max(m, math.max(p.x.abs(), p.y.abs()));
  }
  return m < 50;
}

/// Extracts georeferencing from every page of a parsed PDF.
///
/// Supports:
/// * OGC/Adobe style: page /VP -> /Measure /Subtype /GEO
///   (GPTS lon/lat, LPTS page coords).
/// * TerraGo style: page /LGIDict with /CTM (preferred) or /Registration,
///   plus /Projection /WKT.
class GeorefExtractor {
  GeorefExtractor(this._parser);
  final PdfParser _parser;

  PdfObject _deref(PdfObject? o) => _parser.deref(o);

  /// Returns georeferencing for each page that has any, in page order.
  List<PageGeoref> extractAll() {
    final result = <PageGeoref>[];
    final pages = _parser.pages;
    for (var i = 0; i < pages.length; i++) {
      final g = _extractPage(pages[i], i);
      if (g != null) result.add(g);
    }
    return result;
  }

  PageGeoref? _extractPage(PdfDict page, int pageIndex) {
    final mediaBox = _deref(page['MediaBox']);
    double w = 612, h = 792; // default Letter
    if (mediaBox is PdfArray && mediaBox.items.length >= 4) {
      final n = mediaBox.numbers;
      w = (n[2] - n[0]).abs();
      h = (n[3] - n[1]).abs();
    }
    final rotation = (page.number('Rotate')?.toInt() ?? 0) % 360;

    // 1. OGC style: /VP viewports with /Measure /Subtype /GEO.
    final vp = _deref(page['VP']);
    final vps = <PdfDict>[];
    if (vp is PdfArray) {
      for (final v in vp.items) {
        final d = _deref(v);
        if (d is PdfDict) vps.add(d);
      }
    } else if (vp is PdfDict) {
      vps.add(vp);
    }
    for (final v in vps) {
      final measure = _deref(v['Measure']);
      if (measure is PdfDict &&
          measure.nameValue('Subtype') == 'GEO') {
        final gpts = _pairs(_numbers(_deref(measure['GPTS'])));
        final lpts = _pairs(_numbers(_deref(measure['LPTS'])));
        if (gpts.length < 3 || lpts.length < 3) continue;
        final count = math.min(gpts.length, lpts.length);
        // GPTS pairs are (latitude, longitude) per the geospatial PDF
        // encoding; swap to (lon, lat) for the fit.
        final geo = <math.Point<double>>[
          for (var i = 0; i < count; i++)
            math.Point(gpts[i].y, gpts[i].x),
        ];
        var fit = fitAffine(lpts.take(count).toList(), geo);
        // LPTS are often normalized to the viewport /BBox (Avenza-style,
        // values ~0..1) instead of being given in page points. Fold the
        // page->LPTS normalization into the affine so the rest of the
        // pipeline keeps working in page points.
        final bbox = _deref(v['BBox']);
        if (bbox is PdfArray && _looksNormalized(lpts)) {
          final n = bbox.numbers;
          if (n.length >= 4) {
            final xlo = math.min(n[0], n[2]);
            final xhi = math.max(n[0], n[2]);
            final ylo = math.min(n[1], n[3]);
            final yhi = math.max(n[1], n[3]);
            final bw = xhi - xlo, bh = yhi - ylo;
            if (bw > 0 && bh > 0) {
              fit = [
                fit[0] / bw,
                fit[1] / bh,
                fit[2] - fit[0] * xlo / bw - fit[1] * ylo / bh,
                fit[3] / bw,
                fit[4] / bh,
                fit[5] - fit[3] * xlo / bw - fit[4] * ylo / bh,
              ];
            }
          }
        }
        final gcs = _deref(measure['GCS']);
        String? wkt;
        String? desc;
        if (gcs is PdfDict) {
          wkt = gcs.stringValue('WKT');
          final epsg = gcs.number('EPSG')?.toInt();
          if (epsg != null) desc = 'EPSG:$epsg';
        }
        return PageGeoref(
          pageIndex: pageIndex,
          pageWidthPt: w,
          pageHeightPt: h,
          rotation: rotation,
          kind: GeorefKind.ogc,
          a: fit[0],
          b: fit[1],
          c: fit[2],
          d: fit[3],
          e: fit[4],
          f: fit[5],
          srcIsLonLat: true,
          srcWkt: wkt,
          crsDescription: desc ?? 'WGS 84',
        );
      }
    }

    // 2. TerraGo style: /LGIDict.
    final lgiObj = _deref(page['LGIDict']);
    final lgis = <PdfDict>[];
    if (lgiObj is PdfArray) {
      for (final e in lgiObj.items) {
        final d = _deref(e);
        if (d is PdfDict) lgis.add(d);
      }
    } else if (lgiObj is PdfDict) {
      lgis.add(lgiObj);
    }
    for (final lgi in lgis) {
      String? wkt;
      String? desc;
      final proj = _deref(lgi['Projection']);
      if (proj is PdfDict) {
        wkt = proj.stringValue('WKT');
        desc = _describeTerraGoProjection(proj);
      }

      final ctmObj = _deref(lgi['CTM']);
      if (ctmObj is PdfArray && ctmObj.items.length == 6) {
        // /CTM takes precedence: direct PDF user-space -> projected affine.
        final m = ctmObj.numbers;
        return PageGeoref(
          pageIndex: pageIndex,
          pageWidthPt: w,
          pageHeightPt: h,
          rotation: rotation,
          kind: GeorefKind.terraGo,
          a: m[0],
          b: m[1],
          c: m[4],
          d: m[2],
          e: m[3],
          f: m[5],
          srcIsLonLat: false,
          srcWkt: wkt,
          crsDescription: desc,
        );
      }

      final regObj = _deref(lgi['Registration']);
      if (regObj is PdfArray) {
        final nums = regObj.numbers;
        if (nums.length >= 16 && nums.length % 4 == 0) {
          final src = <math.Point<double>>[];
          final dst = <math.Point<double>>[];
          for (var i = 0; i < nums.length; i += 4) {
            src.add(math.Point(nums[i], nums[i + 1]));
            dst.add(math.Point(nums[i + 2], nums[i + 3]));
          }
          final fit = fitAffine(src, dst);
          return PageGeoref(
            pageIndex: pageIndex,
            pageWidthPt: w,
            pageHeightPt: h,
            rotation: rotation,
            kind: GeorefKind.terraGo,
            a: fit[0],
            b: fit[1],
            c: fit[2],
            d: fit[3],
            e: fit[4],
            f: fit[5],
            srcIsLonLat: false,
            srcWkt: wkt,
            crsDescription: desc,
          );
        }
      }
    }
    return null;
  }

  String? _describeTerraGoProjection(PdfDict proj) {
    final type = proj.stringValue('ProjectionType') ??
        proj.nameValue('ProjectionType');
    final datum = proj.stringValue('Datum') ?? proj.nameValue('Datum');
    final zone = proj.number('Zone')?.toInt();
    final parts = <String>[];
    if (type != null) parts.add(type);
    if (zone != null) parts.add('zone $zone');
    if (datum != null) parts.add(datum);
    return parts.isEmpty ? null : parts.join(' ');
  }
}

/// Maps a rendered-bitmap pixel to unrotated PDF user space (points).
///
/// PDFium applies /Rotate when rendering, so the bitmap's dimensions are
/// the *rotated* page dimensions. [imgW]/[imgH] are bitmap pixels,
/// [pageW]/[pageH] are unrotated page size in points.
math.Point<double> pixelToUserSpace({
  required double px,
  required double py,
  required double imgW,
  required double imgH,
  required double pageW,
  required double pageH,
  required int rotation,
}) {
  // First: pixel -> rotated user space (origin top-left -> bottom-left).
  final sx = imgW / (rotation == 90 || rotation == 270 ? pageH : pageW);
  final sy = imgH / (rotation == 90 || rotation == 270 ? pageW : pageH);
  final rx = px / sx;
  final ry = (imgH - py) / sy;
  // Then unrotate into unrotated user space.
  switch (rotation) {
    case 90:
      return math.Point(pageW - ry, rx);
    case 180:
      return math.Point(pageW - rx, pageH - ry);
    case 270:
      return math.Point(ry, pageH - rx);
    default:
      return math.Point(rx, ry);
  }
}

/// Converts a source-CRS coordinate to WGS84 lon/lat using [wkt].
/// Falls back to treating the input as lon/lat when parsing fails.
math.Point<double> toLonLat(double sx, double sy, String? wkt) {
  if (wkt == null || wkt.isEmpty) {
    return math.Point(sx, sy);
  }
  try {
    final src = proj4.Projection.parse(wkt);
    final p = src.transform(
      proj4.Projection.WGS84,
      proj4.Point(x: sx, y: sy),
    );
    if (!p.x.isFinite || !p.y.isFinite) {
      return math.Point(sx, sy);
    }
    return math.Point(p.x, p.y);
  } catch (_) {
    return math.Point(sx, sy);
  }
}

/// Formats a lon/lat as UTM (e.g. "50S 412300mE 9234500mN").
/// Falls back to a lat/lon string when the transform fails.
String formatUtm(double lon, double lat) {
  try {
    final zone = ((lon + 180) / 6).floor() + 1;
    final south = lat < 0;
    final proj = proj4.Projection.parse(
      '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs'
      '${south ? ' +south' : ''}',
    );
    final p = proj4.Projection.WGS84.transform(
      proj,
      proj4.Point(x: lon, y: lat),
    );
    final hemi = south ? 'S' : 'N';
    return '$zone$hemi ${p.x.toStringAsFixed(0)}mE '
        '${p.y.toStringAsFixed(0)}mN';
  } catch (_) {
    return '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
  }
}
