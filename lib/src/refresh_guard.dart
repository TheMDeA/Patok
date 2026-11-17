/// Serializes an async refresh so overlapping runs can't race on the
/// same map source/layer ids.
///
/// The failure it prevents: a refresh removes a source, spends seconds
/// rendering a PDF page, then re-adds the source — while a second refresh
/// does the same thing. The second run's `addImageSource` then throws
/// `CannotAddSourceException: Source ... already exists`.
///
/// A call made while a run is in flight returns the same future and
/// marks the state stale, so the loop re-runs once afterwards and the
/// latest state wins. Callers awaiting the future always see the final
/// (post re-run) state.
class RefreshGuard {
  Future<void>? _future;
  bool _stale = false;

  /// Runs [body], or joins the in-flight run if one is already going.
  Future<void> run(Future<void> Function() body) {
    if (_future != null) {
      _stale = true;
      return _future!;
    }
    final f = _loop(body);
    _future = f;
    return f.whenComplete(() {
      if (identical(_future, f)) _future = null;
    });
  }

  Future<void> _loop(Future<void> Function() body) async {
    do {
      _stale = false;
      await body();
    } while (_stale);
  }
}
