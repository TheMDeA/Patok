import 'dart:io';

import 'package:flutter/material.dart';

import 'app_scope.dart';
import '../models.dart';
import '../theme.dart';
import 'import_screen.dart';
import 'map_info_sheet.dart';

/// Map library like the approved mockup: search, a "bring your own map"
/// import card, the offline library grouped by recency, and quick filters.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.onOpenMap});

  /// Called when the user taps a map: the home shell switches to the
  /// Map tab and zooms to it.
  final void Function(GeoMap) onOpenMap;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

enum _Filter { recent, downloaded, favorites }

class _LibraryScreenState extends State<LibraryScreen> {
  String _query = '';
  _Filter _filter = _Filter.recent;

  List<GeoMap> get _visibleMaps {
    final maps = AppScope.of(context).library.maps;
    var list = maps.where((m) {
      if (_query.isEmpty) return true;
      return m.name.toLowerCase().contains(_query.toLowerCase());
    }).toList();
    switch (_filter) {
      case _Filter.recent:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case _Filter.downloaded:
        break; // everything here is stored offline on-device
      case _Filter.favorites:
        list = list.where((m) => m.isFavorite).toList();
        break;
    }
    return list;
  }

  Future<void> _import() async {
    final result = await Navigator.push<GeoMap>(
      context,
      MaterialPageRoute(builder: (_) => const ImportScreen()),
    );
    if (result != null && mounted) {
      setState(() {});
      widget.onOpenMap(result);
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _toggleFavorite(GeoMap m) async {
    final scope = AppScope.of(context);
    setState(() => m.isFavorite = !m.isFavorite);
    await scope.library.save();
  }

  Future<void> _delete(GeoMap m) async {
    final scope = AppScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete map?'),
        content: Text(
            '"${m.name}" and its ${m.pages.length} georeferenced page(s) will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await scope.library.remove(m);
      await scope.thumbnailService.deleteThumbnail(m.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final maps = _visibleMaps;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Import map',
            onPressed: _import,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
        children: [
          // Search.
          TextField(
            decoration: InputDecoration(
              hintText: 'Search your maps',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: PatokTheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 16),
          // Import card.
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: PatokTheme.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bring your own map',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Select a georeferenced PDF from device storage. '
                  'Processing stays on-device and visible.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.black.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _import,
                  child: const Text('Import PDF'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'YOUR LIBRARY',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 10),
          if (maps.isEmpty)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                border: Border.all(
                  color: PatokTheme.onSurfaceDim.withValues(alpha: 0.4),
                ),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _filter == _Filter.favorites
                        ? 'No favorites yet'
                        : 'No maps yet',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _filter == _Filter.favorites
                        ? 'Star a map to pin it here.'
                        : 'Imported sheets will be grouped here and available offline.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          else
            ...maps.map((m) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _MapCard(
                    map: m,
                    onOpen: () => widget.onOpenMap(m),
                    onToggleFavorite: () => _toggleFavorite(m),
                    onDelete: () => _delete(m),
                    onShowInfo: () => showMapInfoSheet(context, m),
                  ),
                )),
          const SizedBox(height: 16),
          Text(
            'QUICK FILTERS',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _FilterChip(
                label: 'Recent',
                selected: _filter == _Filter.recent,
                onSelected: () => setState(() => _filter = _Filter.recent),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Downloaded',
                selected: _filter == _Filter.downloaded,
                onSelected: () =>
                    setState(() => _filter = _Filter.downloaded),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Favorites',
                selected: _filter == _Filter.favorites,
                onSelected: () =>
                    setState(() => _filter = _Filter.favorites),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }
}

/// Library card thumbnail: the map's first page rendered small, cached on
/// disk. Falls back to the map icon while loading or when unavailable.
/// The load future is cached per widget so parent rebuilds don't restart it.
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.map});
  final GeoMap map;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  late Future<File?> _future;

  @override
  void initState() {
    super.initState();
    _future = AppScope.of(context).thumbnailService.ensureThumbnail(
      widget.map,
    );
  }

  @override
  void didUpdateWidget(covariant _Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.map.id != widget.map.id) {
      _future = AppScope.of(context).thumbnailService.ensureThumbnail(
        widget.map,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _future,
      builder: (context, snap) {
        final file = snap.data;
        if (file == null) {
          return Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: PatokTheme.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.map, color: PatokTheme.accent),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            file,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.map,
    required this.onOpen,
    required this.onToggleFavorite,
    required this.onDelete,
    required this.onShowInfo,
  });
  final GeoMap map;
  final VoidCallback onOpen;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;
  final VoidCallback onShowInfo;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _Thumbnail(map: map),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(map.name,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '${map.pages.length} georeferenced page(s)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (map.pages.isNotEmpty &&
                        map.pages.first.georef.crsDescription != null)
                      Text(
                        map.pages.first.georef.crsDescription!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'Map info',
                onPressed: onShowInfo,
              ),
              IconButton(
                icon: Icon(
                  map.isFavorite ? Icons.star : Icons.star_outline,
                  color: map.isFavorite ? PatokTheme.accent : null,
                ),
                tooltip: 'Favorite',
                onPressed: onToggleFavorite,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
