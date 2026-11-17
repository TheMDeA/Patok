import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-app update check against the public GitHub releases feed, plus
/// in-app APK download and install (no browser involved).
///
/// Flow: [checkForUpdate] -> if an [UpdateInfo] comes back, show the update
/// sheet -> [downloadAndInstall] streams the APK with progress, then hands
/// it to Android's installer through the `patok/update` method channel.
/// Android shows a one-time "allow installs from this app" system prompt on
/// first use (OS requirement, can't be skipped).
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.releaseNotes,
    required this.apkUrl,
    required this.releaseUrl,
  });

  /// Latest version without the leading "v", e.g. "1.0.2".
  final String version;

  /// Full tag, e.g. "v1.0.2".
  final String tag;

  /// Release notes (changelog markdown) from GitHub.
  final String releaseNotes;

  /// Direct download URL of the release APK.
  final String apkUrl;

  /// Fallback: the release page on github.com.
  final String releaseUrl;
}

const _releasesUrl =
    'https://api.github.com/repos/TheMDeA/Patok/releases/latest';

const _updateChannel = MethodChannel('patok/update');

/// Numeric version comparison: "1.0.10" > "1.0.9". Non-numeric suffixes
/// (e.g. "+3" build metadata) are ignored.
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final l = parts(latest);
  final c = parts(current);
  for (var i = 0; i < l.length || i < c.length; i++) {
    final lv = i < l.length ? l[i] : 0;
    final cv = i < c.length ? c[i] : 0;
    if (lv != cv) return lv > cv;
  }
  return false;
}

/// Returns the installed app version, e.g. "1.0.2".
Future<String> installedVersion() async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
}

/// Checks GitHub for the latest release. Returns [UpdateInfo] when a newer
/// version exists, null when up to date. Throws on network/API errors.
Future<UpdateInfo?> checkForUpdate() async {
  final current = await installedVersion();
  final res = await http.get(
    Uri.parse(_releasesUrl),
    headers: {
      'Accept': 'application/vnd.github+json',
      // GitHub rejects API requests without a User-Agent (403).
      'User-Agent': 'Patok/$current',
    },
  ).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw HttpException(
        'GitHub API returned ${res.statusCode}', uri: Uri.parse(_releasesUrl));
  }
  final json = jsonDecode(res.body) as Map<String, dynamic>;
  final tag = (json['tag_name'] as String? ?? '').trim();
  final version = tag.replaceFirst(RegExp(r'^v'), '');
  if (version.isEmpty || !isNewerVersion(version, current)) return null;

  // Prefer the CI-built APK; fall back to the first .apk asset when a
  // release attaches several (e.g. per-ABI splits).
  String? apkUrl;
  String? firstApkUrl;
  for (final a in (json['assets'] as List? ?? const [])) {
    final name = (a['name'] as String? ?? '').toLowerCase();
    final url = a['browser_download_url'] as String?;
    if (name.endsWith('.apk') && url != null) {
      firstApkUrl ??= url;
      if (name == 'app-release.apk') {
        apkUrl = url;
        break;
      }
    }
  }
  apkUrl ??= firstApkUrl;
  return UpdateInfo(
    version: version,
    tag: tag,
    releaseNotes: (json['body'] as String? ?? '').trim(),
    apkUrl: apkUrl ?? '',
    releaseUrl: (json['html_url'] as String? ?? '').trim(),
  );
}

/// Download progress: 0.0–1.0 fraction (-1 when size unknown) + speed.
class DownloadProgress {
  const DownloadProgress({
    required this.fraction,
    required this.bytesPerSecond,
  });
  final double fraction;
  final double bytesPerSecond;
}

/// File handle for the cached APK of [version]. The file may not exist yet.
Future<File> _apkFile(String version) async {
  final dir = await getTemporaryDirectory();
  return File('${dir.path}/patok-$version.apk');
}

/// True when a complete APK for [version] is already cached — e.g. the
/// download finished but the Android install prompt was dismissed.
/// Existence alone isn't enough: a truncated download must not be
/// mistaken for a finished one, so the file must also look like a valid
/// APK (ZIP local header + end-of-central-directory record).
Future<bool> isApkCached(String version) async {
  final file = await _apkFile(version);
  if (!await file.exists()) return false;
  return _looksLikeApk(file);
}

Future<bool> _looksLikeApk(File file) async {
  try {
    final len = await file.length();
    if (len < 22) return false;
    final raf = await file.open();
    try {
      final head = await raf.read(4);
      if (head.length < 4 ||
          head[0] != 0x50 ||
          head[1] != 0x4B ||
          head[2] != 0x03 ||
          head[3] != 0x04) {
        return false;
      }
      // The end-of-central-directory record (PK\x05\x06) sits in the
      // last 64 KB + 22 bytes; a truncated file doesn't have it.
      final tailLen = len < 65557 ? len : 65557;
      await raf.setPosition(len - tailLen);
      final tail = await raf.read(tailLen);
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4B &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          return true;
        }
      }
      return false;
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}

/// Streams the APK into the cache with progress, writing to a `.part` file
/// first and renaming on completion so a partial download is never mistaken
/// for a finished one.
///
/// Resumes from an existing `.part` file via the HTTP `Range` header, so a
/// dropped connection on weak signal doesn't restart a 50+ MB download
/// from zero. Falls back to a fresh download when the server ignores the
/// range request.
///
/// [isCancelled] is polled between chunks: when it returns true the
/// download stops with [DownloadCancelled] and the `.part` file is kept
/// for a later resume. The body stream times out after 30 s without a
/// chunk, so a stalled connection doesn't hang forever.
Future<void> downloadApk(
  String apkUrl,
  String version, {
  required void Function(DownloadProgress progress) onProgress,
  bool Function()? isCancelled,
  @visibleForTesting http.Client? client,
}) async {
  final owned = client == null;
  client ??= http.Client();
  try {
    final file = await _apkFile(version);
    final part = File('${file.path}.part');
    var resumeFrom = await part.exists() ? await part.length() : 0;

    http.StreamedResponse res = await _sendDownload(client, apkUrl,
        resumeFrom: resumeFrom);

    if (res.statusCode == 416 && resumeFrom > 0) {
      // Range not satisfiable (stale part file): start over once.
      await part.delete();
      resumeFrom = 0;
      res = await _sendDownload(client, apkUrl, resumeFrom: 0);
    } else if (res.statusCode == 206 && resumeFrom > 0) {
      // Server resumed from a different offset than asked: the part file
      // doesn't match this stream, so discard it and start over.
      final start = _rangeStart(res);
      if (start != null && start != resumeFrom) {
        await part.delete();
        resumeFrom = 0;
        res = await _sendDownload(client, apkUrl, resumeFrom: 0);
      }
    }

    final bool resumed = res.statusCode == 206 && resumeFrom > 0;
    if (res.statusCode != 200 && !resumed) {
      throw HttpException('Download returned ${res.statusCode}');
    }
    if (!resumed && resumeFrom > 0) {
      // Server ignored the Range header: discard the partial file.
      await part.delete();
      resumeFrom = 0;
    }

    final total = _totalFrom(res, resumeFrom);
    var received = resumeFrom;
    final sw = Stopwatch()..start();
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    try {
      await for (final chunk
          in res.stream.timeout(const Duration(seconds: 30))) {
        if (isCancelled?.call() == true) throw const DownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        // Throttle progress callbacks: one per 100 ms is plenty for the
        // UI, and per-chunk setState was rebuilding the sheet hundreds
        // of times per second on fast connections.
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds >= 100 ||
            received == total) {
          lastReport = now;
          final secs = sw.elapsedMilliseconds / 1000;
          onProgress(DownloadProgress(
            fraction: total > 0 ? received / total : -1,
            // Speed counts only the bytes fetched this time, not the
            // bytes resumed from a previous attempt.
            bytesPerSecond: secs > 0 ? (received - resumeFrom) / secs : 0,
          ));
        }
      }
    } finally {
      await sink.close();
    }
    // The stream ended: verify the download is actually complete before
    // the .part file is renamed into place, or a truncated APK would be
    // treated as cached and brick the update loop.
    if (total > 0 && received != total) {
      throw HttpException(
          'Download incomplete: received $received of $total bytes');
    }
    await part.rename(file.path);
  } finally {
    if (owned) client.close();
  }
}

/// Start offset of a `Content-Range: bytes <start>-<end>/<total>` header,
/// or null when the header is absent or unparseable.
int? _rangeStart(http.StreamedResponse res) {
  final contentRange = res.headers['content-range'];
  if (contentRange == null) return null;
  final m = RegExp(r'bytes (\d+)-').firstMatch(contentRange);
  return m == null ? null : int.tryParse(m.group(1)!);
}

Future<http.StreamedResponse> _sendDownload(
  http.Client client,
  String apkUrl, {
  required int resumeFrom,
}) async {
  final req = http.Request('GET', Uri.parse(apkUrl));
  req.headers['User-Agent'] = 'Patok';
  if (resumeFrom > 0) req.headers['Range'] = 'bytes=$resumeFrom-';
  return client.send(req).timeout(const Duration(seconds: 30));
}

/// Total download size, accounting for a resumed range response
/// (`Content-Range: bytes 100-999/5000`).
int _totalFrom(http.StreamedResponse res, int resumeFrom) {
  final contentRange = res.headers['content-range'];
  if (contentRange != null) {
    final slash = contentRange.lastIndexOf('/');
    if (slash >= 0) {
      final total = int.tryParse(contentRange.substring(slash + 1));
      if (total != null) return total;
    }
  }
  final len = res.contentLength ?? -1;
  return len > 0 && resumeFrom > 0 ? len + resumeFrom : len;
}

/// Hands the downloaded APK to Android's installer via the `patok/update`
/// method channel.
Future<void> installApk(File file) async {
  await _updateChannel.invokeMethod('installApk', {'path': file.path});
}

/// Downloads the APK to the app cache (reusing it when already cached for
/// [version]) and fires Android's installer.
Future<void> downloadAndInstall(
  String apkUrl, {
  required String version,
  required void Function(DownloadProgress progress) onProgress,
  bool Function()? isCancelled,
}) async {
  if (apkUrl.isEmpty) {
    throw StateError(
        'This release has no APK attached, so it cannot be installed from the app.');
  }
  if (!await isApkCached(version)) {
    await downloadApk(apkUrl, version,
        onProgress: onProgress, isCancelled: isCancelled);
  }
  await installApk(await _apkFile(version));
}

String formatSpeed(double bytesPerSecond) {
  const kb = 1024.0;
  const mb = 1024.0 * 1024.0;
  if (bytesPerSecond >= mb) {
    return '${(bytesPerSecond / mb).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= kb) {
    return '${(bytesPerSecond / kb).toStringAsFixed(1)} KB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}

/// Thrown when the user cancels a download (via the sheet's Cancel
/// button). Not an error: the caller reports it neutrally.
class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Cached SharedPreferences instance: every update helper used to await
/// getInstance() separately, one platform-channel round trip each.
Future<SharedPreferences>? _prefsFuture;
Future<SharedPreferences> _prefs() =>
    _prefsFuture ??= SharedPreferences.getInstance();

/// Daily auto-check preference.
Future<bool> get autoCheckUpdate async {
  final prefs = await _prefs();
  return prefs.getBool('autoCheckUpdate') ?? true;
}

Future<void> setAutoCheckUpdate(bool v) async {
  final prefs = await _prefs();
  await prefs.setBool('autoCheckUpdate', v);
}

/// Checks once a day at startup; returns the [UpdateInfo] when an update
/// is available and the user hasn't dismissed it — the caller decides how
/// to surface it (snackbar, never a blocking dialog). Returns null when
/// disabled, throttled, dismissed, up-to-date, or on any failure.
///
/// Call after the first frame (e.g. from the home shell's initState).
Future<UpdateInfo?> maybeAutoCheckUpdate() async {
  final prefs = await _prefs();
  if (!(prefs.getBool('autoCheckUpdate') ?? true)) return null;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - (prefs.getInt('lastUpdateCheck') ?? 0) <
      const Duration(days: 1).inMilliseconds) {
    return null;
  }
  try {
    final info = await checkForUpdate();
    // Only stamp the check once it actually ran: a failed check (offline,
    // GitHub hiccup) used to suppress the next attempt for a whole day.
    await prefs.setInt('lastUpdateCheck', now);
    if (info == null) return null;
    if (info.version == prefs.getString('dismissedUpdateVersion')) {
      return null;
    }
    return info;
  } catch (_) {
    return null; // Silent: offline or GitHub hiccup.
  }
}

Future<void> dismissUpdateVersion(String version) async {
  final prefs = await _prefs();
  await prefs.setString('dismissedUpdateVersion', version);
}
