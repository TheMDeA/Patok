import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'app_scope.dart';
import '../geopdf/georef.dart';
import '../models.dart';
import '../theme.dart';
import '../waypoint_averaging.dart';
import 'average_waypoint_sheet.dart';
import 'settings_screen.dart';

const _uuid = Uuid();

/// Field tools like the approved mockup: a header, a tool launcher list
/// (my location, add waypoint, measure, record track), then the saved
/// waypoints and measurements.
class FieldScreen extends StatefulWidget {
  const FieldScreen({
    super.key,
    required this.onGoToGps,
    required this.onMeasure,
  });

  /// Switch to the Map tab and center on GPS.
  final VoidCallback onGoToGps;

  /// Switch to the Map tab in measure mode.
  final VoidCallback onMeasure;

  @override
  State<FieldScreen> createState() => FieldScreenState();
}

class FieldScreenState extends State<FieldScreen> {
  List<Waypoint> _waypoints = [];
  List<Measurement> _measurements = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// Reload lists from disk. Called by the home shell when the Field tab
  /// becomes visible, so waypoints added elsewhere (e.g. the map's
  /// crosshair mode) show up immediately.
  Future<void> refresh() => _reload();

  Future<void> _reload() async {
    final store = AppScope.of(context).fieldData;
    final wps = await store.waypoints();
    final ms = await store.measurements();
    if (mounted) {
      setState(() {
        _waypoints = wps;
        _measurements = ms;
        _loading = false;
      });
    }
  }

  Future<void> _addWaypointAtGps() async {
    final scope = AppScope.of(context);
    final pos = await scope.locationService.currentPosition();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No GPS fix yet')),
        );
      }
      return;
    }
    if (!mounted) return;
    final name = await _askName(context, 'Waypoint ${_waypoints.length + 1}');
    if (name == null) return;
    final wps = List<Waypoint>.of(_waypoints)
      ..add(Waypoint(
        id: _uuid.v4(),
        name: name,
        longitude: pos.longitude,
        latitude: pos.latitude,
      ));
    await scope.fieldData.saveWaypoints(wps);
    await _reload();
  }

  Future<void> _averageWaypoint() async {
    final scope = AppScope.of(context);
    final averager = WaypointAverager(scope.locationService);
    try {
      final result = await showAverageWaypointSheet(context, averager);
      if (result == null || !mounted) return;
      final name =
          await _askName(context, 'Waypoint ${_waypoints.length + 1}');
      if (name == null) return;
      final wps = List<Waypoint>.of(_waypoints)
        ..add(Waypoint(
          id: _uuid.v4(),
          name: name,
          longitude: result.longitude,
          latitude: result.latitude,
          note: 'Averaged from ${result.fixCount} fixes '
              '(±${result.precisionMeters.toStringAsFixed(1)} m)',
        ));
      await scope.fieldData.saveWaypoints(wps);
      await _reload();
    } finally {
      averager.dispose();
    }
  }

  Future<String?> _askName(BuildContext context, String hint) {
    final ctrl = TextEditingController(text: hint);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _toggleTrack() async {
    final scope = AppScope.of(context);
    final recorder = scope.trackRecorder;
    if (recorder.isRecording.value) {
      final name = await _askName(
          context, 'Track ${DateTime.now().toIso8601String().substring(0, 10)}');
      if (name == null) return; // keep recording
      final track = await recorder.stop(name);
      if (track != null) {
        final ms = await scope.fieldData.measurements();
        ms.add(track);
        await scope.fieldData.saveMeasurements(ms);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Track saved')),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Track too short — discarded')),
        );
      }
      await _reload();
    } else {
      try {
        await recorder.start();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString())),
          );
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final recorder = scope.trackRecorder;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Field tools'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SettingsScreen()),
              );
              if (mounted) setState(() {});
              await _reload();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              children: [
                // Header card like the mockup.
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: PatokTheme.accent,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(22),
                      topRight: Radius.circular(22),
                      bottomLeft: Radius.circular(22),
                      bottomRight: Radius.circular(7),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Ready for the field',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Tools stay quiet until you need them — '
                        'nothing records without an explicit start.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.black.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Recording indicator.
                ValueListenableBuilder<bool>(
                  valueListenable: recorder.isRecording,
                  builder: (context, recording, _) {
                    if (!recording) return const SizedBox.shrink();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: Colors.red.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.fiber_manual_record,
                              color: Colors.red, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ValueListenableBuilder<int>(
                              valueListenable: recorder.pointCount,
                              builder: (context, n, _) => Text(
                                'Recording track… $n points',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => recorder.cancel().then((_) {
                              if (mounted) setState(() {});
                            }),
                            child: const Text('Discard'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                // Tool launcher like the mockup.
                _ToolTile(
                  icon: Icons.my_location,
                  title: 'My location',
                  subtitle: 'Center GPS on the active map',
                  onTap: widget.onGoToGps,
                ),
                _ToolTile(
                  icon: Icons.add_location_alt,
                  title: 'Add waypoint',
                  subtitle: 'Note the current GPS position',
                  onTap: _addWaypointAtGps,
                ),
                _ToolTile(
                  icon: Icons.adjust,
                  title: 'Average waypoint',
                  subtitle: 'Stand still — average fixes for precision',
                  onTap: _averageWaypoint,
                ),
                _ToolTile(
                  icon: Icons.straighten,
                  title: 'Measure',
                  subtitle: 'Distance on the map',
                  onTap: widget.onMeasure,
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: recorder.isRecording,
                  builder: (context, recording, _) => _ToolTile(
                    icon: recording
                        ? Icons.stop_circle_outlined
                        : Icons.route_outlined,
                    title: recording ? 'Stop track' : 'Record track',
                    subtitle: recording
                        ? 'Finish and save the GPS track'
                        : 'Explicit start, pause-free, explicit stop',
                    highlighted: recording,
                    onTap: _toggleTrack,
                  ),
                ),
                const SizedBox(height: 20),
                _SectionHeader(
                    'WAYPOINTS (${_waypoints.length})'),
                const SizedBox(height: 8),
                if (_waypoints.isEmpty)
                  Text(
                    'No waypoints yet.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  ..._waypoints.map((w) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.place,
                              color: PatokTheme.accent),
                          title: Text(w.name),
                          subtitle: Text(
                            formatUtm(w.longitude, w.latitude) +
                                (w.note != null ? '\n${w.note}' : ''),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final store = scope.fieldData;
                              final messenger = ScaffoldMessenger.of(context);
                              final idx = _waypoints.indexOf(w);
                              final wps =
                                  List<Waypoint>.of(_waypoints)
                                    ..removeWhere(
                                        (e) => e.id == w.id);
                              await store.saveWaypoints(wps);
                              await _reload();
                              messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        'Waypoint "${w.name}" deleted'),
                                    action: SnackBarAction(
                                      label: 'Undo',
                                      onPressed: () async {
                                        final restored =
                                            List<Waypoint>.of(_waypoints)
                                              ..insert(
                                                  idx.clamp(
                                                      0, _waypoints.length),
                                                  w);
                                        await store.saveWaypoints(restored);
                                        await _reload();
                                      },
                                    ),
                                  ),
                                );
                            },
                          ),
                        ),
                      )),
                const SizedBox(height: 16),
                _SectionHeader(
                    'MEASUREMENTS (${_measurements.length})'),
                const SizedBox(height: 8),
                if (_measurements.isEmpty)
                  Text(
                    'No measurements yet.',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  ..._measurements.map((m) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.straighten,
                              color: PatokTheme.accent),
                          title: Text(m.name),
                          subtitle: Text(
                              '${_fmtLen(m.lengthMeters)} • ${m.points.length} points'
                              '${m.areaSqMeters != null ? ' • ${_fmtArea(m.areaSqMeters!)}' : ''}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final store = scope.fieldData;
                              final messenger = ScaffoldMessenger.of(context);
                              final idx = _measurements.indexOf(m);
                              final ms =
                                  List<Measurement>.of(_measurements)
                                    ..removeWhere(
                                        (e) => e.id == m.id);
                              await store.saveMeasurements(ms);
                              await _reload();
                              messenger.showSnackBar(
                                  SnackBar(
                                    content:
                                        Text('"${m.name}" deleted'),
                                    action: SnackBarAction(
                                      label: 'Undo',
                                      onPressed: () async {
                                        final restored =
                                            List<Measurement>.of(
                                                    _measurements)
                                              ..insert(
                                                  idx.clamp(0,
                                                      _measurements.length),
                                                  m);
                                        await store
                                            .saveMeasurements(restored);
                                        await _reload();
                                      },
                                    ),
                                  ),
                                );
                            },
                          ),
                        ),
                      )),
              ],
            ),
    );
  }

  String _fmtLen(double m) => m < 1000
      ? '${m.toStringAsFixed(1)} m'
      : '${(m / 1000).toStringAsFixed(2)} km';

  String _fmtArea(double sqm) => sqm < 10000
      ? '${sqm.toStringAsFixed(0)} m²'
      : '${(sqm / 10000).toStringAsFixed(2)} ha';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            letterSpacing: 1.2,
            fontWeight: FontWeight.w800,
          ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: highlighted
          ? PatokTheme.accent.withValues(alpha: 0.15)
          : null,
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: PatokTheme.accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: PatokTheme.accent),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
