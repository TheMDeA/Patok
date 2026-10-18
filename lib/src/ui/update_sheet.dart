import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../update_service.dart';

/// Shows the "Update available" bottom sheet for [info].
Future<void> showUpdateSheet(BuildContext context, UpdateInfo info) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _UpdateSheet(info: info),
  );
}

enum _Phase { idle, downloading, installing }

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  double _speedBps = 0;
  String? _currentVersion;
  bool _cached = false;

  @override
  void initState() {
    super.initState();
    installedVersion().then((v) {
      if (mounted) setState(() => _currentVersion = v);
    });
    // A previous download may already be in the cache (e.g. the Android
    // install prompt was dismissed) — then we can install directly.
    isApkCached(widget.info.version).then((c) {
      if (mounted) setState(() => _cached = c);
    });
  }

  Future<void> _download() async {
    HapticFeedback.mediumImpact();
    try {
      final cached = await isApkCached(widget.info.version);
      if (cached) {
        setState(() => _phase = _Phase.installing);
      } else {
        setState(() {
          _phase = _Phase.downloading;
          _progress = 0;
        });
      }
      await downloadAndInstall(
        widget.info.apkUrl,
        version: widget.info.version,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            if (p.fraction >= 0) _progress = p.fraction;
            _speedBps = p.bytesPerSecond;
          });
        },
      );
      if (!mounted) return;
      setState(() => _phase = _Phase.installing);
      // The OS installer takes over from here.
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: ${_friendlyError(e)}')),
      );
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    return msg.replaceFirst(RegExp(r'^(Exception|StateError):\s*'), '');
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final textTheme = Theme.of(context).textTheme;
    final downloading = _phase == _Phase.downloading;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: PatokTheme.surface2,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Text(
                  'Update available',
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await dismissUpdateVersion(info.version);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              children: [
                Row(
                  children: [
                    _versionChip(_currentVersion ?? '…', false),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.arrow_forward,
                          size: 18, color: PatokTheme.onSurfaceDim),
                    ),
                    _versionChip(info.version, true),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  "What's new",
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: PatokTheme.onSurfaceDim,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: PatokTheme.surface2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      info.releaseNotes.isEmpty
                          ? 'No release notes.'
                          : info.releaseNotes,
                      style:
                          const TextStyle(fontSize: 13, height: 1.45),
                    ),
                  ),
                ),
                if (downloading) ...[
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _progress > 0 ? _progress : null,
                      minHeight: 8,
                      backgroundColor: PatokTheme.surface2,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          PatokTheme.accent),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Downloading the update — keep the app open.',
                    style: textTheme.bodySmall?.copyWith(
                      color: PatokTheme.onSurfaceDim,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: PatokTheme.accent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed:
                        _phase == _Phase.idle ? _download : null,
                    child: Text(
                      switch (_phase) {
                        _Phase.idle => _cached
                            ? 'Install update'
                            : 'Download update',
                        _Phase.downloading => _speedBps > 0
                            ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}% • ${formatSpeed(_speedBps)}'
                            : 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%',
                        _Phase.installing => 'Opening installer…',
                      },
                    ),
                  ),
                ),
                SizedBox(
                    height:
                        MediaQuery.of(context).padding.bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _versionChip(String version, bool isNew) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isNew
            ? PatokTheme.accent.withValues(alpha: 0.2)
            : PatokTheme.surface2,
        borderRadius: BorderRadius.circular(12),
        border: isNew
            ? Border.all(color: PatokTheme.accent.withValues(alpha: 0.5))
            : null,
      ),
      child: Text(
        version,
        style: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.bold,
          color: isNew
              ? PatokTheme.accent
              : PatokTheme.onSurfaceDim,
        ),
      ),
    );
  }
}
