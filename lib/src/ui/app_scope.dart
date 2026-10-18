import 'package:flutter/widgets.dart';

import '../services.dart';

/// Simple service locator for the app's singletons.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.library,
    required this.renderService,
    required this.importService,
    required this.thumbnailService,
    required this.locationService,
    required this.gnssService,
    required this.trackRecorder,
    required this.settings,
    required this.fieldData,
    required super.child,
  });

  final MapLibrary library;
  final RenderService renderService;
  final ImportService importService;
  final ThumbnailService thumbnailService;
  final LocationService locationService;
  final GnssService gnssService;
  final TrackRecorder trackRecorder;
  final SettingsService settings;
  final FieldDataStore fieldData;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}
