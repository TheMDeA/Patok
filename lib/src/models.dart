import 'dart:convert';

/// How a page's georeferencing was encoded in the PDF.
enum GeorefKind {
  /// OGC/Adobe style: page /VP viewport + /Measure /Subtype /GEO
  /// (GPTS pairs are (latitude, longitude); swapped to lon/lat on read).
  ogc,

  /// TerraGo style: /LGIDict with /Registration or /CTM
  /// (coordinates are in the /Projection CRS, need reprojection).
  terraGo,
}

/// Georeferencing for a single PDF page.
///
/// [pageToSrc] is an affine transform mapping unrotated PDF user-space
/// points (in points, 1/72 inch, origin bottom-left) to source-CRS
/// coordinates: `sx = a*x + b*y + c`, `sy = d*x + e*y + f`.
/// When [srcIsLonLat] is true the source CRS is already WGS84 lon/lat;
/// otherwise [srcWkt] describes the CRS and coordinates must be
/// reprojected to lon/lat via PROJ.
class PageGeoref {
  PageGeoref({
    required this.pageIndex,
    required this.pageWidthPt,
    required this.pageHeightPt,
    required this.rotation,
    required this.kind,
    required this.a,
    required this.b,
    required this.c,
    required this.d,
    required this.e,
    required this.f,
    required this.srcIsLonLat,
    this.srcWkt,
    this.crsDescription,
  });

  final int pageIndex;
  final double pageWidthPt;
  final double pageHeightPt;

  /// Page /Rotate value, one of 0/90/180/270.
  final int rotation;
  final GeorefKind kind;
  final double a, b, c, d, e, f;
  final bool srcIsLonLat;
  final String? srcWkt;
  final String? crsDescription;

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'pageWidthPt': pageWidthPt,
        'pageHeightPt': pageHeightPt,
        'rotation': rotation,
        'kind': kind.name,
        'a': a,
        'b': b,
        'c': c,
        'd': d,
        'e': e,
        'f': f,
        'srcIsLonLat': srcIsLonLat,
        'srcWkt': srcWkt,
        'crsDescription': crsDescription,
      };

  factory PageGeoref.fromJson(Map<String, dynamic> j) => PageGeoref(
        pageIndex: (j['pageIndex'] as num).toInt(),
        pageWidthPt: (j['pageWidthPt'] as num).toDouble(),
        pageHeightPt: (j['pageHeightPt'] as num).toDouble(),
        rotation: (j['rotation'] as num).toInt(),
        kind: GeorefKind.values.byName(j['kind'] as String),
        a: (j['a'] as num).toDouble(),
        b: (j['b'] as num).toDouble(),
        c: (j['c'] as num).toDouble(),
        d: (j['d'] as num).toDouble(),
        e: (j['e'] as num).toDouble(),
        f: (j['f'] as num).toDouble(),
        srcIsLonLat: j['srcIsLonLat'] as bool,
        srcWkt: j['srcWkt'] as String?,
        crsDescription: j['crsDescription'] as String?,
      );
}

/// One georeferenced page of an imported map, with its corner
/// coordinates in WGS84 (for the map overlay + library display).
class GeoMapPage {
  GeoMapPage({
    required this.pageIndex,
    required this.name,
    required this.georef,
    required this.cornerLonLat,
  });

  final int pageIndex;
  final String name;
  final PageGeoref georef;

  /// [topLeft, topRight, bottomRight, bottomLeft] as (lon, lat).
  final List<List<double>> cornerLonLat;

  Map<String, dynamic> toJson() => {
        'pageIndex': pageIndex,
        'name': name,
        'georef': georef.toJson(),
        'cornerLonLat': cornerLonLat,
      };

  factory GeoMapPage.fromJson(Map<String, dynamic> j) => GeoMapPage(
        pageIndex: (j['pageIndex'] as num).toInt(),
        name: j['name'] as String,
        georef: PageGeoref.fromJson(j['georef'] as Map<String, dynamic>),
        cornerLonLat: (j['cornerLonLat'] as List)
            .map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
      );
}

/// An imported map in the library.
class GeoMap {
  GeoMap({
    required this.id,
    required this.name,
    required this.fileName,
    required this.pages,
    this.visible = true,
    this.opacity = 1.0,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  final String id;
  String name;
  final String fileName;

  /// Relative path of the copied PDF inside the app documents directory.
  String get relativePdfPath => 'maps/$id.pdf';

  final List<GeoMapPage> pages;
  bool visible;
  double opacity;
  final DateTime addedAt;

  int get georeferencedPages => pages.length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'fileName': fileName,
        'pages': pages.map((p) => p.toJson()).toList(),
        'visible': visible,
        'opacity': opacity,
        'addedAt': addedAt.toIso8601String(),
      };

  factory GeoMap.fromJson(Map<String, dynamic> j) => GeoMap(
        id: j['id'] as String,
        name: j['name'] as String,
        fileName: j['fileName'] as String,
        pages: (j['pages'] as List)
            .map((p) => GeoMapPage.fromJson(p as Map<String, dynamic>))
            .toList(),
        visible: j['visible'] as bool? ?? true,
        opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
        addedAt: DateTime.parse(j['addedAt'] as String),
      );

  static String encodeList(List<GeoMap> maps) =>
      jsonEncode(maps.map((m) => m.toJson()).toList());

  static List<GeoMap> decodeList(String s) => (jsonDecode(s) as List)
      .map((j) => GeoMap.fromJson(j as Map<String, dynamic>))
      .toList();
}

/// A saved waypoint.
class Waypoint {
  Waypoint({
    required this.id,
    required this.name,
    required this.longitude,
    required this.latitude,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;
  final double longitude;
  final double latitude;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'longitude': longitude,
        'latitude': latitude,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
        id: j['id'] as String,
        name: j['name'] as String,
        longitude: (j['longitude'] as num).toDouble(),
        latitude: (j['latitude'] as num).toDouble(),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

/// A saved measurement (polyline with computed length, optionally area).
class Measurement {
  Measurement({
    required this.id,
    required this.name,
    required this.points,
    required this.lengthMeters,
    this.areaSqMeters,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String name;

  /// (lon, lat) pairs.
  final List<List<double>> points;
  final double lengthMeters;
  final double? areaSqMeters;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'points': points,
        'lengthMeters': lengthMeters,
        'areaSqMeters': areaSqMeters,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Measurement.fromJson(Map<String, dynamic> j) => Measurement(
        id: j['id'] as String,
        name: j['name'] as String,
        points: (j['points'] as List)
            .map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
        lengthMeters: (j['lengthMeters'] as num).toDouble(),
        areaSqMeters: (j['areaSqMeters'] as num?)?.toDouble(),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}
