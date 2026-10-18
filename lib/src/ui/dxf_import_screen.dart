import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dxf/dxf_crs.dart';
import '../dxf/dxf_import.dart';
import '../dxf/dxf_model.dart';
import 'app_scope.dart';

/// One reference point of a new local grid: local E/N plus the
/// real-world position (set via GPS, map pick, or typed lat/lon).
class DxfRefPoint {
  String easting = '';
  String northing = '';
  double? lon;
  double? lat;

  bool get hasLocal =>
      double.tryParse(easting) != null && double.tryParse(northing) != null;
  bool get hasReal => lon != null && lat != null;
  bool get complete => hasLocal && hasReal;
}

/// Mutable state for the DXF import flow. Owned by the caller
/// (LibraryScreen) so it survives the pop/re-push around map picking.
class DxfImportFlow {
  DxfParseResult? parsed;
  String name = '';

  bool useUtm = true;
  int utmZone = 50;
  bool utmSouth = true;
  DxfLocalGrid? selectedGrid;

  String gridName = '';
  final List<DxfRefPoint> refPoints = [DxfRefPoint(), DxfRefPoint()];

  void setRealPosition(int index, double? lon, double? lat) {
    refPoints[index].lon = lon;
    refPoints[index].lat = lat;
  }

  /// The CRS to import with, or null when the choice is incomplete.
  DxfCrs? get crs {
    if (useUtm) {
      return DxfUtm(zone: utmZone, southernHemisphere: utmSouth);
    }
    return selectedGrid;
  }
}

/// Returned from [DxfImportScreen] when the user asks to pick a
/// reference-point position on the map. The caller performs the pick,
/// stores it in the flow, and re-pushes the screen.
class DxfPickRequested {
  DxfPickRequested(this.pointIndex, this.prompt);
  final int pointIndex;
  final String prompt;
}

enum _Step { pick, summary, crs, newGrid, importing }

/// DXF import flow: pick file -> summary -> coordinate system ->
/// (new local grid with two reference points) -> import.
///
/// Map picking is done by popping with [DxfPickRequested]; the owner
/// re-pushes this screen with the same [flow] afterwards.
class DxfImportScreen extends StatefulWidget {
  const DxfImportScreen({super.key, required this.flow});

  final DxfImportFlow flow;

  @override
  State<DxfImportScreen> createState() => _DxfImportScreenState();
}

class _DxfImportScreenState extends State<DxfImportScreen> {
  _Step _step = _Step.pick;
  String _progress = 'Opening file picker…';
  String? _error;

  List<DxfLocalGrid> _grids = [];
  bool _gridsLoading = true;

  // New-grid form controllers (synced back into the flow).
  final _gridNameCtl = TextEditingController();
  final List<TextEditingController> _eCtls = [
    TextEditingController(),
    TextEditingController(),
  ];
  final List<TextEditingController> _nCtls = [
    TextEditingController(),
    TextEditingController(),
  ];
  final List<TextEditingController> _latCtls = [
    TextEditingController(),
    TextEditingController(),
  ];
  final List<TextEditingController> _lonCtls = [
    TextEditingController(),
    TextEditingController(),
  ];
  final List<bool> _showLatLon = [false, false];
  final List<bool> _gpsBusy = [false, false];
  String? _gridError;
  String? _gridPreview;

  @override
  void initState() {
    super.initState();
    final flow = widget.flow;
    _gridNameCtl.text = flow.gridName;
    _gridNameCtl.addListener(() => flow.gridName = _gridNameCtl.text);
    for (var i = 0; i < 2; i++) {
      final rp = flow.refPoints[i];
      _eCtls[i].text = rp.easting;
      _nCtls[i].text = rp.northing;
      _eCtls[i].addListener(() {
        rp.easting = _eCtls[i].text;
        _updateGridPreview();
      });
      _nCtls[i].addListener(() {
        rp.northing = _nCtls[i].text;
        _updateGridPreview();
      });
      if (rp.lat != null) _latCtls[i].text = rp.lat.toString();
      if (rp.lon != null) _lonCtls[i].text = rp.lon.toString();
      _latCtls[i].addListener(() {
        rp.lat = double.tryParse(_latCtls[i].text);
        _updateGridPreview();
      });
      _lonCtls[i].addListener(() {
        rp.lon = double.tryParse(_lonCtls[i].text);
        _updateGridPreview();
      });
    }
    // Restore remembered UTM defaults + saved grids.
    final scope = AppScope.of(context);
    widget.flow.utmZone = scope.settings.lastDxfUtmZone;
    widget.flow.utmSouth = scope.settings.lastDxfUtmSouth;
    _loadGrids();
    // Start the picker right away, unless we're returning from a map pick
    // (parsed is already set).
    if (flow.parsed == null) {
      Future.microtask(_pickFile);
    } else {
      _step = _Step.summary;
      if (flow.name.isEmpty) {
        flow.name = flow.parsed!.fileName
            .replaceAll(RegExp(r'\.dxf$', caseSensitive: false), '');
      }
    }
  }

  Future<void> _loadGrids() async {
    final grids = await AppScope.of(context).localGrids.all();
    if (!mounted) return;
    setState(() {
      _grids = grids;
      _gridsLoading = false;
      // Preselect a grid that survived the round-trip.
      final sel = widget.flow.selectedGrid;
      if (sel != null) {
        final match = grids.where((g) => g.name == sel.name).toList();
        widget.flow.selectedGrid = match.isEmpty ? null : match.first;
      }
    });
  }

  @override
  void dispose() {
    _gridNameCtl.dispose();
    for (final c in [
      ..._eCtls,
      ..._nCtls,
      ..._latCtls,
      ..._lonCtls,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _step = _Step.pick;
      _error = null;
      _progress = 'Opening file picker…';
    });
    try {
      final svc = AppScope.of(context).importService;
      final parsed = await svc.pickAndParseDxf((msg) {
        if (mounted) setState(() => _progress = msg);
      });
      if (parsed == null) {
        if (mounted) Navigator.pop(context); // cancelled
        return;
      }
      widget.flow.parsed = parsed;
      widget.flow.name = parsed.fileName
          .replaceAll(RegExp(r'\.dxf$', caseSensitive: false), '');
      if (mounted) setState(() => _step = _Step.summary);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  // ------------------------------------------------------------ grid form

  /// Live solve preview: shows scale/rotation once both points are
  /// complete, or the reason they don't solve.
  void _updateGridPreview() {
    final flow = widget.flow;
    if (_step != _Step.newGrid) return;
    String? preview;
    if (flow.refPoints.every((p) => p.complete)) {
      try {
        final g = _buildGrid(flow);
        preview = 'Scale ${g.scale.toStringAsFixed(4)} • '
            'rotation ${g.rotationDeg.toStringAsFixed(1)}°';
        if ((g.scale - 1).abs() > 0.1) {
          preview += '\nUnusual scale — check the reference points.';
        }
      } on StateError catch (e) {
        preview = e.message;
      }
    }
    if (mounted && preview != _gridPreview) {
      setState(() => _gridPreview = preview);
    }
  }

  DxfLocalGrid _buildGrid(DxfImportFlow flow) {
    final a = flow.refPoints[0];
    final b = flow.refPoints[1];
    final lon = (a.lon! + b.lon!) / 2;
    return DxfLocalGrid(
      name: flow.gridName.trim().isEmpty ? 'Local grid' : flow.gridName.trim(),
      zone: utmZoneFor(lon),
      southernHemisphere: ((a.lat! + b.lat!) / 2) < 0,
      e1: double.parse(a.easting),
      n1: double.parse(a.northing),
      lon1: a.lon!,
      lat1: a.lat!,
      e2: double.parse(b.easting),
      n2: double.parse(b.northing),
      lon2: b.lon!,
      lat2: b.lat!,
    );
  }

  Future<void> _saveGrid() async {
    final flow = widget.flow;
    setState(() => _gridError = null);
    if (flow.gridName.trim().isEmpty) {
      setState(() => _gridError = 'Give the grid a name.');
      return;
    }
    for (var i = 0; i < 2; i++) {
      final p = flow.refPoints[i];
      if (!p.hasLocal) {
        setState(
            () => _gridError = 'Point ${i + 1}: enter local easting/northing.');
        return;
      }
      if (!p.hasReal) {
        setState(() => _gridError =
            'Point ${i + 1}: set its real-world position (GPS, map, or lat/lon).');
        return;
      }
    }
    DxfLocalGrid grid;
    try {
      grid = _buildGrid(flow);
    } on StateError catch (e) {
      setState(() => _gridError = e.message);
      return;
    }
    final store = AppScope.of(context).localGrids;
    final grids = await store.all();
    grids.removeWhere((g) => g.name == grid.name);
    grids.add(grid);
    await store.saveAll(grids);
    flow.selectedGrid = grid;
    flow.useUtm = false;
    if (mounted) {
      setState(() {
        _grids = grids;
        _step = _Step.crs;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Grid "${grid.name}" saved '
            '(scale ${grid.scale.toStringAsFixed(4)}, '
            'rotation ${grid.rotationDeg.toStringAsFixed(1)}°)',
          ),
        ),
      );
    }
  }

  Future<void> _useGps(int i) async {
    setState(() => _gpsBusy[i] = true);
    try {
      final pos =
          await AppScope.of(context).locationService.currentPosition();
      if (!mounted) return;
      if (pos == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No GPS position available')),
        );
        return;
      }
      widget.flow.setRealPosition(i, pos.longitude, pos.latitude);
      _latCtls[i].text = pos.latitude.toStringAsFixed(6);
      _lonCtls[i].text = pos.longitude.toStringAsFixed(6);
      _updateGridPreview();
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _gpsBusy[i] = false);
    }
  }

  void _pickOnMap(int i) {
    // The owner (LibraryScreen) pops this screen, runs the map pick on
    // the Map tab, then re-pushes with the same flow.
    Navigator.pop(
      context,
      DxfPickRequested(i, 'Pick reference point ${i + 1}'),
    );
  }

  // ---------------------------------------------------------------- import

  Future<void> _doImport() async {
    final flow = widget.flow;
    final crs = flow.crs;
    if (crs == null) return;
    setState(() {
      _step = _Step.importing;
      _error = null;
    });
    try {
      final scope = AppScope.of(context);
      final imp = await scope.importService.commitDxfImport(
        parsed: flow.parsed!,
        crs: crs,
        name: flow.name.trim().isEmpty ? flow.parsed!.fileName : flow.name.trim(),
        onProgress: (msg) {
          if (mounted) setState(() => _progress = msg);
        },
      );
      if (crs is DxfUtm) {
        await scope.settings.setLastDxfUtm(crs.zone, crs.southernHemisphere);
      }
      if (mounted) Navigator.pop(context, imp);
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _Step.crs;
          _error = e.toString().replaceFirst('StateError: ', '');
        });
      }
    }
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import DXF')),
      body: _error != null && _step != _Step.crs && _step != _Step.newGrid
          ? _ErrorView(message: _error!, onRetry: _pickFile)
          : switch (_step) {
              _Step.pick => _ProgressView(message: _progress),
              _Step.summary => _SummaryStep(
                  flow: widget.flow,
                  onNext: () => setState(() => _step = _Step.crs),
                  onRename: (v) => widget.flow.name = v,
                ),
              _Step.crs => _CrsStep(
                  flow: widget.flow,
                  grids: _grids,
                  gridsLoading: _gridsLoading,
                  error: _error,
                  onChanged: () => setState(() => _error = null),
                  onNewGrid: () {
                    setState(() {
                      _gridError = null;
                      _gridPreview = null;
                      _step = _Step.newGrid;
                    });
                    _updateGridPreview();
                  },
                  onImport: _doImport,
                ),
              _Step.newGrid => _NewGridStep(
                  flow: widget.flow,
                  gridNameCtl: _gridNameCtl,
                  eCtls: _eCtls,
                  nCtls: _nCtls,
                  latCtls: _latCtls,
                  lonCtls: _lonCtls,
                  showLatLon: _showLatLon,
                  gpsBusy: _gpsBusy,
                  error: _gridError,
                  preview: _gridPreview,
                  onToggleLatLon: (i) =>
                      setState(() => _showLatLon[i] = !_showLatLon[i]),
                  onGps: _useGps,
                  onPickMap: _pickOnMap,
                  onBack: () => setState(() => _step = _Step.crs),
                  onSave: _saveGrid,
                ),
              _Step.importing => _ProgressView(message: _progress),
            },
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
      child: Padding(
        padding: const EdgeInsets.all(24),
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
      ),
    );
  }
}

/// Step 2: what was parsed — entity counts, native bounds, CAD layers.
class _SummaryStep extends StatelessWidget {
  const _SummaryStep({
    required this.flow,
    required this.onNext,
    required this.onRename,
  });
  final DxfImportFlow flow;
  final VoidCallback onNext;
  final void Function(String) onRename;

  @override
  Widget build(BuildContext context) {
    final doc = flow.parsed!.doc;
    final counts = <String, int>{};
    for (final e in doc.entities) {
      final k = switch (e) {
        DxfLine() => 'Lines',
        DxfPolyline() => 'Polylines',
        DxfPointEntity() => 'Points',
        DxfText() => 'Texts',
        DxfCircle() => 'Circles',
        DxfArc() => 'Arcs',
        DxfHatch() => 'Hatches',
        _ => 'Other',
      };
      counts[k] = (counts[k] ?? 0) + 1;
    }
    final b = doc.bounds; // [minX, minY, maxX, maxY] native
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: flow.name,
            decoration: const InputDecoration(
              labelText: 'Drawing name',
              border: OutlineInputBorder(),
            ),
            onChanged: onRename,
          ),
          const SizedBox(height: 16),
          Text('Contents', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  for (final e in counts.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(e.key),
                          Text('${e.value}',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('CAD layers'),
                      Text('${doc.layers.length}'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Native extents'),
                      Flexible(
                        child: Text(
                          b == null
                              ? '—'
                              : 'E ${b[0].toStringAsFixed(0)}…${b[2].toStringAsFixed(0)}\n'
                                  'N ${b[1].toStringAsFixed(0)}…${b[3].toStringAsFixed(0)}',
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onNext,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Choose coordinate system'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Step 3: UTM zone or a saved local grid.
class _CrsStep extends StatelessWidget {
  const _CrsStep({
    required this.flow,
    required this.grids,
    required this.gridsLoading,
    required this.error,
    required this.onChanged,
    required this.onNewGrid,
    required this.onImport,
  });
  final DxfImportFlow flow;
  final List<DxfLocalGrid> grids;
  final bool gridsLoading;
  final String? error;
  final VoidCallback onChanged;
  final VoidCallback onNewGrid;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final crs = flow.crs;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('UTM')),
              ButtonSegment(value: false, label: Text('Local grid')),
            ],
            selected: {flow.useUtm},
            onSelectionChanged: (s) {
              flow.useUtm = s.first;
              onChanged();
            },
          ),
          const SizedBox(height: 16),
          if (flow.useUtm) ...[
            Text('UTM zone', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: flow.utmZone,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Zone',
                    ),
                    items: [
                      for (var z = 1; z <= 60; z++)
                        DropdownMenuItem(value: z, child: Text('Zone $z')),
                    ],
                    onChanged: (z) {
                      if (z != null) {
                        flow.utmZone = z;
                        onChanged();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('N')),
                    ButtonSegment(value: true, label: Text('S')),
                  ],
                  selected: {flow.utmSouth},
                  onSelectionChanged: (s) {
                    flow.utmSouth = s.first;
                    onChanged();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Applies to the whole drawing. The zone is remembered for next time.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else ...[
            Text('Mine grid', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (gridsLoading)
              const Center(child: CircularProgressIndicator())
            else if (grids.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                      'No local grids yet. Define one from two reference points.'),
                ),
              )
            else
              RadioGroup<DxfLocalGrid>(
                groupValue: flow.selectedGrid,
                onChanged: (v) {
                  flow.selectedGrid = v;
                  onChanged();
                },
                child: Column(
                  children: [
                    for (final g in grids)
                      RadioListTile<DxfLocalGrid>(
                        title: Text(g.name),
                        subtitle: Text(
                          'UTM ${g.zone}${g.southernHemisphere ? 'S' : 'N'} • '
                          'scale ${g.scale.toStringAsFixed(4)} • '
                          'rot ${g.rotationDeg.toStringAsFixed(1)}°',
                        ),
                        value: g,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onNewGrid,
              icon: const Icon(Icons.add),
              label: const Text('New local grid'),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: TextStyle(color: Colors.redAccent[100])),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: crs == null ? null : onImport,
              icon: const Icon(Icons.download),
              label: Text(crs == null
                  ? 'Pick a coordinate system first'
                  : 'Import drawing'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Step 4: define a new local grid from two reference points.
class _NewGridStep extends StatelessWidget {
  const _NewGridStep({
    required this.flow,
    required this.gridNameCtl,
    required this.eCtls,
    required this.nCtls,
    required this.latCtls,
    required this.lonCtls,
    required this.showLatLon,
    required this.gpsBusy,
    required this.error,
    required this.preview,
    required this.onToggleLatLon,
    required this.onGps,
    required this.onPickMap,
    required this.onBack,
    required this.onSave,
  });
  final DxfImportFlow flow;
  final TextEditingController gridNameCtl;
  final List<TextEditingController> eCtls;
  final List<TextEditingController> nCtls;
  final List<TextEditingController> latCtls;
  final List<TextEditingController> lonCtls;
  final List<bool> showLatLon;
  final List<bool> gpsBusy;
  final String? error;
  final String? preview;
  final void Function(int) onToggleLatLon;
  final Future<void> Function(int) onGps;
  final void Function(int) onPickMap;
  final VoidCallback onBack;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextFormField(
          controller: gridNameCtl,
          decoration: const InputDecoration(
            labelText: 'Grid name',
            hintText: 'e.g. Pit Timur grid',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 8),
        Text(
          'Two points you can identify both on the drawing and in the real world '
          '(survey markers work best). Stand at each one or pick it on the map.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < 2; i++) ...[
          _RefPointCard(
            index: i,
            point: flow.refPoints[i],
            eCtl: eCtls[i],
            nCtl: nCtls[i],
            latCtl: latCtls[i],
            lonCtl: lonCtls[i],
            showLatLon: showLatLon[i],
            gpsBusy: gpsBusy[i],
            onToggleLatLon: () => onToggleLatLon(i),
            onGps: () => onGps(i),
            onPickMap: () => onPickMap(i),
          ),
          const SizedBox(height: 12),
        ],
        if (preview != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(preview!),
            ),
          ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: TextStyle(color: Colors.redAccent[100])),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onBack,
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: onSave,
                icon: const Icon(Icons.save),
                label: const Text('Save grid'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RefPointCard extends StatelessWidget {
  const _RefPointCard({
    required this.index,
    required this.point,
    required this.eCtl,
    required this.nCtl,
    required this.latCtl,
    required this.lonCtl,
    required this.showLatLon,
    required this.gpsBusy,
    required this.onToggleLatLon,
    required this.onGps,
    required this.onPickMap,
  });
  final int index;
  final DxfRefPoint point;
  final TextEditingController eCtl;
  final TextEditingController nCtl;
  final TextEditingController latCtl;
  final TextEditingController lonCtl;
  final bool showLatLon;
  final bool gpsBusy;
  final VoidCallback onToggleLatLon;
  final VoidCallback onGps;
  final VoidCallback onPickMap;

  @override
  Widget build(BuildContext context) {
    final hasReal = point.hasReal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Point ${index + 1}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (hasReal)
                  const Icon(Icons.check_circle,
                      color: Colors.greenAccent, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: eCtl,
                    decoration: const InputDecoration(
                      labelText: 'Local easting',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9.\-]')),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: nCtl,
                    decoration: const InputDecoration(
                      labelText: 'Local northing',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9.\-]')),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (hasReal)
              Text(
                '${point.lat!.toStringAsFixed(6)}, ${point.lon!.toStringAsFixed(6)}',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              Text(
                'Real-world position not set',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: gpsBusy ? null : onGps,
                  icon: gpsBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.gps_fixed, size: 18),
                  label: const Text('GPS'),
                ),
                OutlinedButton.icon(
                  onPressed: onPickMap,
                  icon: const Icon(Icons.map, size: 18),
                  label: const Text('Map'),
                ),
                OutlinedButton.icon(
                  onPressed: onToggleLatLon,
                  icon: const Icon(Icons.edit_location_alt, size: 18),
                  label: const Text('Lat/Lon'),
                ),
              ],
            ),
            if (showLatLon) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: latCtl,
                      decoration: const InputDecoration(
                        labelText: 'Latitude',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: lonCtl,
                      decoration: const InputDecoration(
                        labelText: 'Longitude',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
