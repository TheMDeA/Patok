import 'package:flutter/material.dart';

import '../theme.dart';
import '../waypoint_averaging.dart';

/// Bottom sheet that collects GPS fixes while the user stands still and
/// shows the running average. Returns the [AverageResult] on save, or null
/// when cancelled / too few fixes.
Future<AverageResult?> showAverageWaypointSheet(
  BuildContext context,
  WaypointAverager averager,
) {
  return showModalBottomSheet<AverageResult?>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (ctx) => _AverageWaypointSheet(averager: averager),
  );
}

class _AverageWaypointSheet extends StatefulWidget {
  const _AverageWaypointSheet({required this.averager});
  final WaypointAverager averager;

  @override
  State<_AverageWaypointSheet> createState() => _AverageWaypointSheetState();
}

class _AverageWaypointSheetState extends State<_AverageWaypointSheet> {
  int _target = 60;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.averager.start().catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
      return null;
    });
  }

  @override
  void dispose() {
    widget.averager.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: PatokTheme.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Averaging waypoint',
              style: textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Stand still — random GPS error cancels out',
              style: textTheme.bodySmall
                  ?.copyWith(color: PatokTheme.onSurfaceDim),
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red))
            else
              ValueListenableBuilder<int>(
                valueListenable: widget.averager.fixCount,
                builder: (context, count, _) {
                  final done = count >= _target;
                  return Column(
                    children: [
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: (count / _target).clamp(0.0, 1.0),
                              strokeWidth: 8,
                              backgroundColor: PatokTheme.surface2,
                              valueColor:
                                  const AlwaysStoppedAnimation<Color>(
                                      PatokTheme.accent),
                            ),
                            Text(
                              '$count',
                              style: textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        done ? 'Target reached' : 'of $_target fixes',
                        style: textTheme.bodySmall?.copyWith(
                            color: PatokTheme.onSurfaceDim),
                      ),
                    ],
                  );
                },
              ),
            const SizedBox(height: 16),
            ValueListenableBuilder<AverageResult?>(
              valueListenable: widget.averager.average,
              builder: (context, avg, _) {
                if (avg == null) {
                  return Text(
                    'Waiting for first fix…',
                    style: textTheme.bodyMedium?.copyWith(
                        color: PatokTheme.onSurfaceDim),
                  );
                }
                return Column(
                  children: [
                    Text(
                      '${avg.latitude.toStringAsFixed(6)}, '
                      '${avg.longitude.toStringAsFixed(6)}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '±${avg.precisionMeters.toStringAsFixed(1)} m',
                      style: textTheme.titleMedium?.copyWith(
                        color: PatokTheme.accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [30, 60, 120].map((t) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text('$t'),
                    selected: _target == t,
                    onSelected: (_) =>
                        setState(() => _target = t),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: widget.averager.fixCount,
                    builder: (context, count, _) => FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: PatokTheme.accent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: count >= 10
                          ? () {
                              final r = widget.averager
                                  .stop(minFixes: 10);
                              Navigator.of(context).pop(r);
                            }
                          : null,
                      child: const Text('Save'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Save needs at least 10 fixes',
              style: textTheme.bodySmall
                  ?.copyWith(color: PatokTheme.onSurfaceDim),
            ),
          ],
        ),
      ),
    );
  }
}
