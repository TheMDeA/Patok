import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/services.dart';
import 'src/theme.dart';
import 'src/ui/app_scope.dart';
import 'src/ui/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsService.load();
  final library = await MapLibrary.load();
  final renderService = RenderService();
  final importService = ImportService(library, renderService);
  final locationService = LocationService();
  final fieldData = await FieldDataStore.load();

  // Edge-to-edge for the full-bleed map.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  runApp(
    AppScope(
      library: library,
      renderService: renderService,
      importService: importService,
      locationService: locationService,
      settings: settings,
      fieldData: fieldData,
      child: PatokApp(settings: settings),
    ),
  );
}

class PatokApp extends StatefulWidget {
  const PatokApp({super.key, required this.settings});
  final SettingsService settings;

  @override
  State<PatokApp> createState() => _PatokAppState();
}

class _PatokAppState extends State<PatokApp> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.settings.sunlightModeListenable,
      builder: (context, sunlight, _) => MaterialApp(
        title: 'Patok',
        debugShowCheckedModeBanner: false,
        theme: PatokTheme.dark(sunlightMode: sunlight),
        home: const MapScreen(),
      ),
    );
  }
}
