import 'package:flutter/services.dart';

/// Receives PDFs shared from other apps ("Open with Patok").
///
/// Backed by the `patok/share` event channel in MainActivity, which copies
/// the shared content URI into the app cache and reports its absolute path.
/// A share that launches the app (cold start) is buffered natively and
/// delivered on first listen; shares while the app runs arrive live.
class ShareIntentService {
  static const _channel = EventChannel('patok/share');

  /// Absolute paths of shared PDFs, in arrival order.
  Stream<String> get sharedPdfStream => _channel
      .receiveBroadcastStream()
      .where((e) => e is String)
      .cast<String>();
}
