import 'package:flutter/material.dart';

import 'app_scope.dart';
import '../models.dart';
import 'import_screen.dart';

/// Map library: list of imported georeferenced PDFs.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return Scaffold(
      appBar: AppBar(title: const Text('Map library')),
      body: library.maps.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.map_outlined,
                      size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    'No maps imported yet',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Import a georeferenced PDF\n(OGC or TerraGo style)',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _import,
                    icon: const Icon(Icons.file_download),
                    label: const Text('Import map'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: library.maps.length,
              itemBuilder: (_, i) {
                final m = library.maps[i];
                return _MapCard(
                  map: m,
                  onDelete: () => _delete(m),
                  onTap: () => Navigator.pop(context, m),
                );
              },
            ),
      floatingActionButton: library.maps.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _import,
              icon: const Icon(Icons.file_download),
              label: const Text('Import'),
            ),
    );
  }

  Future<void> _import() async {
    final result = await Navigator.push<GeoMap>(
      context,
      MaterialPageRoute(builder: (_) => const ImportScreen()),
    );
    if (result != null && mounted) setState(() {});
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
      if (mounted) setState(() {});
    }
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.map,
    required this.onDelete,
    required this.onTap,
  });
  final GeoMap map;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.map,
                    color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(map.name,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '${map.pages.length} georeferenced page(s) • ${map.fileName}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (map.pages.isNotEmpty &&
                        map.pages.first.georef.crsDescription != null)
                      Text(
                        map.pages.first.georef.crsDescription!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
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
