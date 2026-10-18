import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  String? apkUrl;
  for (final a in (json['assets'] as List? ?? const [])) {
    final name = (a['name'] as String? ?? '').toLowerCase();
    final url = a['browser_download_url'] as String?;
    if (name.endsWith('.apk') && url != null) {
      apkUrl = url;
      break;
    }
  }
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
Future<bool> isApkCached(String version) async =>
    await (await _apkFile(version)).exists();

/// Streams the APK into the cache with progress, writing to a `.part` file
/// first and renaming on completion so a partial download is never mistaken
/// for a finished one.
Future<void> downloadApk(
  String apkUrl,
  String version, {
  required void Function(DownloadProgress progress) onProgress,
}) async {
  final client = http.Client();
  try {
    final req = http.Request('GET', Uri.parse(apkUrl));
    req.headers['User-Agent'] = 'Patok';
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw HttpException('Download returned ${res.statusCode}');
    }
    final total = res.contentLength ?? -1;
    final file = await _apkFile(version);
    final part = File('${file.path}.part');
    var received = 0;
    final sw = Stopwatch()..start();
    final sink = part.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        final secs = sw.elapsedMilliseconds / 1000;
        onProgress(DownloadProgress(
          fraction: total > 0 ? received / total : -1,
          bytesPerSecond: secs > 0 ? received / secs : 0,
        ));
      }
    } finally {
      await sink.close();
    }
    await part.rename(file.path);
  } finally {
    client.close();
  }
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
}) async {
  if (!await isApkCached(version)) {
    await downloadApk(apkUrl, version, onProgress: onProgress);
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

/// Daily auto-check preference.
Future<bool> get autoCheckUpdate async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('autoCheckUpdate') ?? true;
}

Future<void> setAutoCheckUpdate(bool v) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('autoCheckUpdate', v);
}

/// Checks once a day at startup; returns the [UpdateInfo] when an update
/// is available and the user hasn't dismissed it — the caller decides how
/// to surface it (snackbar, never a blocking dialog). Returns null when
/// disabled, throttled, dismissed, up-to-date, or on any failure.
///
/// Call after the first frame (e.g. from the home shell's initState).
Future<UpdateInfo?> maybeAutoCheckUpdate() async {
  final prefs = await SharedPreferences.getInstance();
  if (!(prefs.getBool('autoCheckUpdate') ?? true)) return null;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - (prefs.getInt('lastUpdateCheck') ?? 0) <
      const Duration(days: 1).inMilliseconds) {
    return null;
  }
  await prefs.setInt('lastUpdateCheck', now);
  try {
    final info = await checkForUpdate();
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
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('dismissedUpdateVersion', version);
}
