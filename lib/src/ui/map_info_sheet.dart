import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

/// Bottom sheet with a map's metadata: file, pages, georeferencing method,
/// coordinate system, page size, and bounds. Builds trust that the map is
/// placed correctly.
Future<void> showMapInfoSheet(BuildContext context, GeoMap map) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _MapInfoSheet(map: map),
  );
}

class _MapInfoSheet extends StatelessWidget {
  const _MapInfoSheet({required this.map});
  final GeoMap map;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: PatokTheme.surface2,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              map.name,
              style: textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              map.fileName,
              style: textTheme.bodySmall?.copyWith(
                color: PatokTheme.onSurfaceDim,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _row('Pages',
                      '${map.pages.length} georeferenced'),
                  _row('Added',
                      '${map.addedAt.day}/${map.addedAt.month}/${map.addedAt.year}'),
                  const SizedBox(height: 12),
                  for (var i = 0; i < map.pages.length; i++) ...[
                    Text(
                      'Page ${map.pages[i].pageIndex + 1}',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: PatokTheme.accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _pageRows(map.pages[i]),
                    if (i < map.pages.length - 1)
                      const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                  color: PatokTheme.onSurfaceDim),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageRows(GeoMapPage page) {
    final g = page.georef;
    final method = switch (g.kind) {
      GeorefKind.ogc => 'OGC (/VP viewport + /Measure)',
      GeorefKind.terraGo => 'TerraGo (/LGIDict)',
    };
    final wIn = g.pageWidthPt / 72;
    final hIn = g.pageHeightPt / 72;
    var minLon = double.infinity,
        maxLon = -double.infinity,
        minLat = double.infinity,
        maxLat = -double.infinity;
    for (final c in page.cornerLonLat) {
      if (c[0] < minLon) minLon = c[0];
      if (c[0] > maxLon) maxLon = c[0];
      if (c[1] < minLat) minLat = c[1];
      if (c[1] > maxLat) maxLat = c[1];
    }
    return Column(
      children: [
        _row('Method', method),
        if (g.crsDescription != null)
          _row('Coords', g.crsDescription!),
        _row('Page size',
            '${wIn.toStringAsFixed(1)} × ${hIn.toStringAsFixed(1)} in'),
        if (g.rotation != 0) _row('Rotation', '${g.rotation}°'),
        _row(
          'Bounds',
          '${minLon.toStringAsFixed(4)}, ${minLat.toStringAsFixed(4)}\n'
          '${maxLon.toStringAsFixed(4)}, ${maxLat.toStringAsFixed(4)}',
        ),
      ],
    );
  }
}
