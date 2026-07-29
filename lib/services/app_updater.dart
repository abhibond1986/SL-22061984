// lib/services/app_updater.dart
// ★ v24: Auto-update service — downloads APK and triggers install.
//
// Flow:
//   1. Gets current app version from Android PackageManager
//   2. Checks GitHub Releases API for a newer version
//   3. Downloads APK to cache
//   4. Triggers install via PackageInstaller (silent if same signing key)
//      OR falls back to ACTION_VIEW intent (shows one-tap install prompt)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';

class AppUpdater {
  // ── Config ─────────────────────────────────────────────────────────────────
  static const String _owner = 'abhibond1986';
  static const String _repo = 'SL-22061984';

  /// Fallback version if native query fails — should match pubspec.yaml
  static const String _fallbackVersion = '1.0.97';

  /// How often to check for updates (in minutes) — aggressive for enterprise deployment
  static const int _checkIntervalMinutes = 15;

  /// How many times to retry offering the same version before giving up
  static const int _maxAttempts = 10;

  /// Periodic check timer
  static Timer? _periodicTimer;

  static const String _lastCheckKey = 'app_updater_last_check';
  static const String _lastVersionKey = 'app_updater_last_installed';
  static const String _attemptCountKey = 'app_updater_attempt_count';
  static const String _kCurrentVersion = 'app_updater_current_version';

  /// Method channel for native install + version query
  static const MethodChannel _channel =
      MethodChannel('com.sail.safety/app_updater');

  /// Cached current version
  static String? _currentVersion;

  /// Get current app version from native Android PackageManager
  static Future<String> getCurrentVersion() async {
    if (_currentVersion != null) return _currentVersion!;
    try {
      final version = await _channel.invokeMethod<String>('getAppVersion');
      _currentVersion = version ?? _fallbackVersion;
    } catch (_) {
      _currentVersion = _fallbackVersion;
    }
    return _currentVersion!;
  }

  /// Initialize — check for updates immediately and start periodic checks.
  /// Call this from main.dart after app startup.
  static Future<void> init() async {
    if (kIsWeb) return;
    if (!Platform.isAndroid) return;

    // Run initial check
    await _performCheck();

    // Start periodic background checks every _checkIntervalMinutes
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(
      Duration(minutes: _checkIntervalMinutes),
      (_) => _performCheck(),
    );
    debugPrint('[AppUpdater] Periodic check started (every ${_checkIntervalMinutes}min)');
  }

  /// Stop periodic checks (call on app dispose if needed)
  static void dispose() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Internal: perform one update check cycle
  static Future<void> _performCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final minsSinceLastCheck = (now - lastCheck) / (1000 * 60);

    // Rate limit: don't check more than once per 5 minutes (safety net)
    if (minsSinceLastCheck < 5) {
      debugPrint('[AppUpdater] Skipping — last check ${minsSinceLastCheck.toStringAsFixed(0)}min ago');
      return;
    }

    await prefs.setInt(_lastCheckKey, now);

    final currentVer = await getCurrentVersion();
    final lastAttemptedVer = prefs.getString(_lastVersionKey) ?? '';
    if (lastAttemptedVer.isNotEmpty && _isNewerVersion(lastAttemptedVer, currentVer)) {
      debugPrint('[AppUpdater] v$lastAttemptedVer was attempted but not installed (still on v$currentVer)');
    }

    try {
      final updateInfo = await _checkForUpdate();
      if (updateInfo != null) {
        final lastAttempted = prefs.getString(_lastVersionKey) ?? '';
        final attemptCount = prefs.getInt(_attemptCountKey) ?? 0;
        if (lastAttempted == updateInfo.version && attemptCount >= _maxAttempts) {
          debugPrint('[AppUpdater] Already attempted v${updateInfo.version} $attemptCount times — skipping');
          return;
        }

        if (lastAttempted != updateInfo.version) {
          await prefs.setInt(_attemptCountKey, 1);
        } else {
          await prefs.setInt(_attemptCountKey, attemptCount + 1);
        }

        debugPrint('[AppUpdater] Update available: v${updateInfo.version} (current: $currentVer, attempt: ${attemptCount + 1})');
        await _downloadAndInstall(updateInfo);
      } else {
        debugPrint('[AppUpdater] App is up to date (v$currentVer)');
      }
    } catch (e) {
      debugPrint('[AppUpdater] Check failed: $e');
    }
  }

  /// Check GitHub Releases API for a newer version
  static Future<UpdateInfo?> _checkForUpdate() async {
    final url = Uri.parse(
        'https://api.github.com/repos/$_owner/$_repo/releases/latest');

    final response = await http.get(url, headers: {
      'Accept': 'application/vnd.github.v3+json',
    }).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('GitHub API returned ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tagName = (data['tag_name'] ?? '') as String;
    final releaseName = (data['name'] ?? '') as String;
    final body = (data['body'] ?? '') as String;

    final remoteVersion = tagName.replaceAll(RegExp(r'^v'), '');
    final currentVer = await getCurrentVersion();

    if (!_isNewerVersion(remoteVersion, currentVer)) {
      return null;
    }

    // Find APK asset in release
    String? apkUrl;
    int? apkSize;
    final assets = (data['assets'] as List?) ?? [];
    for (final asset in assets) {
      final name = (asset['name'] ?? '') as String;
      if (name.toLowerCase().endsWith('.apk')) {
        apkUrl = asset['browser_download_url'] as String?;
        apkSize = asset['size'] as int?;
        break;
      }
    }

    if (apkUrl == null) return null; // No APK attached to release

    return UpdateInfo(
      version: remoteVersion,
      releaseName: releaseName,
      releaseNotes: body,
      downloadUrl: apkUrl,
      apkSize: apkSize ?? 0,
      publishedAt: data['published_at'] as String? ?? '',
    );
  }

  /// Compare semantic versions: returns true if remote > current
  static bool _isNewerVersion(String remote, String current) {
    try {
      final remoteParts = remote.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();

      while (remoteParts.length < 3) remoteParts.add(0);
      while (currentParts.length < 3) currentParts.add(0);

      for (int i = 0; i < 3; i++) {
        if (remoteParts[i] > currentParts[i]) return true;
        if (remoteParts[i] < currentParts[i]) return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Download APK and trigger install
  static Future<void> _downloadAndInstall(UpdateInfo info) async {
    try {
      debugPrint('[AppUpdater] Downloading APK (${info.apkSize} bytes)...');

      // Download to app's internal cache directory (no permissions needed)
      final cacheDir = await getTemporaryDirectory();
      final apkFile = File('${cacheDir.path}/safety_lens_update.apk');

      // Clean up old APK if present
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      // Download the APK — GitHub uses redirects for asset downloads
      final apkBytes = await _downloadWithRedirects(info.downloadUrl);
      if (apkBytes == null || apkBytes.isEmpty) {
        debugPrint('[AppUpdater] Download returned empty');
        return;
      }

      await apkFile.writeAsBytes(apkBytes);
      debugPrint('[AppUpdater] APK saved: ${apkFile.lengthSync()} bytes');

      // Verify file is reasonable size (at least 5MB for a Flutter app)
      if (apkFile.lengthSync() < 5 * 1024 * 1024) {
        debugPrint('[AppUpdater] Downloaded file too small (${apkFile.lengthSync()} bytes) — likely not a valid APK');
        await apkFile.delete();
        return;
      }

      // Trigger install via native Android code
      final result = await _channel.invokeMethod('installApk', {
        'apkPath': apkFile.path,
      });

      debugPrint('[AppUpdater] Install triggered: $result');

      // Record that we triggered an install for this version
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastVersionKey, info.version);
    } catch (e) {
      debugPrint('[AppUpdater] Download/install failed: $e');
    }
  }

  /// Download file following HTTP redirects (GitHub uses 302s for assets)
  static Future<List<int>?> _downloadWithRedirects(String url, {int maxRedirects = 5}) async {
    var currentUrl = url;
    for (int i = 0; i < maxRedirects; i++) {
      final request = http.Request('GET', Uri.parse(currentUrl));
      request.followRedirects = false;

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 10),
      );

      if (streamedResponse.statusCode == 200) {
        return await streamedResponse.stream.toBytes();
      } else if (streamedResponse.statusCode == 302 || streamedResponse.statusCode == 301) {
        final redirectUrl = streamedResponse.headers['location'];
        if (redirectUrl == null || redirectUrl.isEmpty) {
          debugPrint('[AppUpdater] Redirect with no location header');
          return null;
        }
        currentUrl = redirectUrl;
        debugPrint('[AppUpdater] Following redirect → ${currentUrl.substring(0, 80)}...');
      } else {
        debugPrint('[AppUpdater] Download HTTP ${streamedResponse.statusCode}');
        return null;
      }
    }
    debugPrint('[AppUpdater] Too many redirects');
    return null;
  }

  /// Force check now (e.g., from settings/admin screen)
  static Future<String> checkNow() async {
    try {
      final currentVer = await getCurrentVersion();
      final info = await _checkForUpdate();
      if (info != null) {
        await _downloadAndInstall(info);
        return 'Update v${info.version} downloading... (current: v$currentVer)';
      }
      return 'App is up to date (v$currentVer)';
    } catch (e) {
      return 'Check failed: $e';
    }
  }

  /// Call this when app resumes from background to check immediately
  static Future<void> onAppResumed() async {
    if (kIsWeb || !Platform.isAndroid) return;
    // Check immediately on resume (rate-limited internally)
    await _performCheck();
  }
}

/// Update information model
class UpdateInfo {
  final String version;
  final String releaseName;
  final String releaseNotes;
  final String downloadUrl;
  final int apkSize;
  final String publishedAt;

  UpdateInfo({
    required this.version,
    required this.releaseName,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.apkSize,
    required this.publishedAt,
  });
}
