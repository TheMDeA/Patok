import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'app_scope.dart';

/// Storage manager: per-map disk usage (PDF + cached thumbnail) with a
/// one-tap clear of regenerable previews.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _MapUsage {
  _MapUsage(this.map, this.pdfBytes, this.thumbBytes);
  final GeoMap map;
  final int pdfBytes;
  final int thumbBytes;
  int get total => pdfBytes + thumbBytes;
}

class _StorageScreenState extends State<StorageScreen> {
  List<_MapUsage> _usage = [];
  bool _loading = true;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<int> _sizeOf(File f) async {
    try {
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final scope = AppScope.of(context);
    final usage = <_MapUsage>[];
    for (final m in scope.library.maps) {
      final pdfBytes = await _sizeOf(File(scope.library.pdfPath(m)));
      final thumbBytes =
          await _sizeOf(await scope.thumbnailService.thumbnailFile(m.id));
      usage.add(_MapUsage(m, pdfBytes, thumbBytes));
    }
    usage.sort((a, b) => b.total.compareTo(a.total));
    if (mounted) {
      setState(() {
        _usage = usage;
        _loading = false;
      });
    }
  }

  Future<void> _clearThumbnails() async {
    final scope = AppScope.of(context);
    setState(() => _clearing = true);
    try {
      for (final u in _usage) {
        await scope.thumbnailService.deleteThumbnail(u.map.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Cached previews cleared — they rebuild '
                  'automatically')),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
      await _reload();
    }
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final total = _usage.fold<int>(0, (s, u) => s + u.total);
    final thumbs = _usage.fold<int>(0, (s, u) => s + u.thumbBytes);
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Total map storage',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(
                          _fmt(total),
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(color: PatokTheme.accent),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonalIcon(
                            onPressed: _clearing || thumbs == 0
                                ? null
                                : _clearThumbnails,
                            icon: _clearing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.cleaning_services_outlined),
                            label: Text(
                                'Clear cached previews (${_fmt(thumbs)})'),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Previews rebuild automatically when you open '
                          'the library.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final u in _usage)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.map_outlined,
                          color: PatokTheme.accent),
                      title: Text(u.map.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          'Map file ${_fmt(u.pdfBytes)} · Preview ${_fmt(u.thumbBytes)}'),
                      trailing: Text(
                        _fmt(u.total),
                        style:
                            const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                if (_usage.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                        child: Text('No maps yet — nothing stored.')),
                  ),
              ],
            ),
    );
  }
}
