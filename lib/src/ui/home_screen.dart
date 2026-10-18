import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import '../update_service.dart';
import 'field_screen.dart';
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
  }

  void _openMap(GeoMap map) {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapState?.openMap(map);
    });
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
    setState(() => _index = i);
    if (i == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mapState?.didBecomeVisible();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          MapScreen(key: _mapKey, onBrowseMaps: _goToLibrary),
          LibraryScreen(onOpenMap: _openMap),
          FieldScreen(
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
