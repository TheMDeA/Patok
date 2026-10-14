import 'package:flutter/material.dart';

import 'app_scope.dart';
import '../models.dart';

/// Import flow: pick a PDF -> parse with progress -> show georeferenced
/// pages -> add to the map.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  String _progress = '';
  GeoMap? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Start the picker right away.
    Future.microtask(_start);
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _result = null;
      _progress = 'Opening file picker…';
    });
    try {
      final map = await AppScope.of(context)
          .importService
          .importWithPicker((msg) {
        if (mounted) setState(() => _progress = msg);
      });
      if (map == null) {
        // User cancelled the picker.
        if (mounted) Navigator.pop(context);
        return;
      }
      if (mounted) {
        setState(() {
          _result = map;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import map')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _error != null
            ? _ErrorView(message: _error!, onRetry: _start)
            : _result != null
                ? _ResultView(map: _result!)
                : _ProgressView(message: _progress),
      ),
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.redAccent),
          const SizedBox(height: 16),
          Text('Import failed',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try another file'),
          ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.map});
  final GeoMap map;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle,
                color: Colors.greenAccent, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(map.name,
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    '${map.pages.length} georeferenced page(s) found',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Pages', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: map.pages.length,
            itemBuilder: (_, i) {
              final p = map.pages[i];
              final g = p.georef;
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.map_outlined),
                  title: Text(p.name),
                  subtitle: Text(
                    '${g.kind.name.toUpperCase()} • '
                    '${g.crsDescription ?? 'WGS 84'} • '
                    '${g.pageWidthPt.toStringAsFixed(0)}×'
                    '${g.pageHeightPt.toStringAsFixed(0)} pt',
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => Navigator.pop(context, map),
            icon: const Icon(Icons.map),
            label: const Text('Add to map'),
          ),
        ),
      ],
    );
  }
}
