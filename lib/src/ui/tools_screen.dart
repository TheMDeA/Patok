import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'app_scope.dart';
import '../geopdf/georef.dart';
import '../models.dart';

const _uuid = Uuid();

/// Field tools: waypoints and saved measurements.
class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  List<Waypoint> _waypoints = [];
  List<Measurement> _measurements = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Field tools'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Waypoints'),
            Tab(text: 'Measurements'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _WaypointList(
                  waypoints: _waypoints,
                  onDelete: (w) async {
                    final wps = List<Waypoint>.of(_waypoints)
                      ..removeWhere((e) => e.id == w.id);
                    await scope.fieldData.saveWaypoints(wps);
                    await _reload();
                  },
                ),
                _MeasurementList(
                  measurements: _measurements,
                  onDelete: (m) async {
                    final ms = List<Measurement>.of(_measurements)
                      ..removeWhere((e) => e.id == m.id);
                    await scope.fieldData.saveMeasurements(ms);
                    await _reload();
                  },
                ),
              ],
            ),
      floatingActionButton: _tabs.index == 0
          ? FloatingActionButton.extended(
              onPressed: _addWaypointAtGps,
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Waypoint at GPS'),
            )
          : null,
    );
  }
}

class _WaypointList extends StatelessWidget {
  const _WaypointList({required this.waypoints, required this.onDelete});
  final List<Waypoint> waypoints;
  final void Function(Waypoint) onDelete;

  @override
  Widget build(BuildContext context) {
    if (waypoints.isEmpty) {
      return const Center(
          child: Text('No waypoints yet.\nAdd one at your GPS position.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: waypoints.length,
      itemBuilder: (_, i) {
        final w = waypoints[i];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.place),
            title: Text(w.name),
            subtitle: Text(formatUtm(w.longitude, w.latitude)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => onDelete(w),
            ),
          ),
        );
      },
    );
  }
}

class _MeasurementList extends StatelessWidget {
  const _MeasurementList(
      {required this.measurements, required this.onDelete});
  final List<Measurement> measurements;
  final void Function(Measurement) onDelete;

  String _fmt(double m) =>
      m < 1000 ? '${m.toStringAsFixed(1)} m' : '${(m / 1000).toStringAsFixed(2)} km';

  @override
  Widget build(BuildContext context) {
    if (measurements.isEmpty) {
      return const Center(
          child: Text(
              'No measurements yet.\nUse the measure tool on the map.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: measurements.length,
      itemBuilder: (_, i) {
        final m = measurements[i];
        return Card(
          child: ListTile(
            leading: const Icon(Icons.straighten),
            title: Text(m.name),
            subtitle: Text(
                '${_fmt(m.lengthMeters)} • ${m.points.length} points'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => onDelete(m),
            ),
          ),
        );
      },
    );
  }
}
