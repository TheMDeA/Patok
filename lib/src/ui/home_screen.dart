import 'dart:async';

import 'package:flutter/material.dart';

import '../dxf/dxf_import.dart';
import '../models.dart';
import '../share_intent_service.dart';
import '../theme.dart';
import '../update_service.dart';
import 'field_screen.dart';
import 'import_screen.dart';
import 'library_screen.dart';
import 'map_screen.dart';
import 'update_sheet.dart';

/// App shell: bottom navigation (Map | Library | Field) like the approved
/// mockup. Opens on the Library tab so the app doesn't dump the user
/// straight into the map.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Library first: the map tab is one tap away, but the app opens on
  /// the library / main menu.
  int _index = 1;
  final _mapKey = GlobalKey<MapScreenState>();
  final _fieldKey = GlobalKey<FieldScreenState>();

  MapScreenState? get _mapState => _mapKey.currentState;

  @override
  void initState() {
    super.initState();
    // Daily update check, after the first frame. Surfaces as a snackbar —
    // never a blocking dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final info = await maybeAutoCheckUpdate();
      if (!mounted || info == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Update available: Patok ${info.version}'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () => showUpdateSheet(context, info),
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    });
    // "Open with Patok": a PDF shared from another app. Cold-start shares
    // are buffered natively and delivered on first listen; later shares
    // arrive live on the same stream.
    _shareSub = ShareIntentService().sharedPdfStream.listen((path) {
      if (mounted) _importShared(path);
    });
  }

  StreamSubscription<String>? _shareSub;

  /// Imports a PDF shared from another app, then opens it on the map.
  Future<void> _importShared(String path) async {
    if (!path.toLowerCase().endsWith('.pdf')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Patok can only open PDF files')),
        );
      }
      return;
    }
    final map = await Navigator.push<GeoMap>(
      context,
      MaterialPageRoute(
          builder: (_) => ImportScreen(sharedPath: path)),
    );
    if (map != null && mounted) _openMap(map);
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  void _openMap(GeoMap map) {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapState?.openMap(map);
    });
  }

  void _openDxf(DxfImport imp) {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapState?.openDxf(imp);
    });
  }

  /// Map-tab point picker for DXF grid calibration: switches to the Map
  /// tab, waits for the native map, and completes with the picked
  /// position (or null if cancelled / unavailable).
  Future<({double lon, double lat})?> _pickPointOnMap(String prompt) async {
    _onTab(0);
    for (var i = 0; i < 50; i++) {
      if (_mapState?.isMapReady ?? false) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    final pt = await _mapState?.pickPoint(prompt: prompt);
    if (pt == null) return null;
    return (lon: pt.longitude, lat: pt.latitude);
  }

  void _goToGps() {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapState?.goToGps();
    });
  }

  void _startMeasure() {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapState?.startMeasureMode();
    });
  }

  void _goToLibrary() => setState(() => _index = 1);

  void _onTab(int i) {
    // A tab switch away from the map cancels an active point pick so the
    // caller (DXF grid calibration) never hangs.
    if (i != 0 && (_mapState?.isPicking ?? false)) {
      _mapState?.cancelPick();
    }
    setState(() => _index = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (i == 0) {
        _mapState?.didBecomeVisible();
      } else if (i == 2) {
        _fieldKey.currentState?.refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          MapScreen(
              key: _mapKey, onBrowseMaps: _goToLibrary, onOpenField: () => _onTab(2)),
          LibraryScreen(
            onOpenMap: _openMap,
            onOpenDxf: _openDxf,
            onPickPointOnMap: _pickPointOnMap,
          ),
          FieldScreen(
            key: _fieldKey,
            onGoToGps: _goToGps,
            onMeasure: _startMeasure,
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: _onTab,
        backgroundColor: PatokTheme.surface,
        selectedItemColor: PatokTheme.accent,
        unselectedItemColor: PatokTheme.onSurfaceDim,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder_outlined),
            activeIcon: Icon(Icons.folder),
            label: 'Library',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.build_outlined),
            activeIcon: Icon(Icons.build),
            label: 'Field',
          ),
        ],
      ),
    );
  }
}
