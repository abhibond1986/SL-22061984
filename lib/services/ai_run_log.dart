// lib/services/ai_run_log.dart
//
// AI RUN TELEMETRY — one record per AI analysis attempt.
//
// WHY THIS EXISTS
//   There was no way to answer "how is my AI model actually performing?".
//   The reason is subtle and worth stating, because it makes the naive version
//   of this feature useless: GeminiVision NEVER THROWS on failure. When every
//   provider fails it returns _offlineFallback(), a perfectly well-formed map
//   containing a generic checklist with riskScore 0 and _isOnline false. The
//   caller cannot tell that apart from a real answer without inspecting the
//   private flags, so:
//     • ai_scan_tab's catch block almost never fires — a total AI outage looks
//       like a normal scan to the UI;
//     • ErrorLogService therefore recorded almost nothing, and its
//       getSuccessRate() was a placeholder computing (100 - errors)/100 with no
//       success counter at all (its own source said "TODO: Track successful
//       operations");
//     • near_miss_tab swallowed every failure in bare `catch (_) {}`;
//     • the one Stopwatch in the app (gemini_vision.dart) measured every run
//       and only printed the result to the debug console.
//
//   So this service records runs EXPLICITLY at each exit point of the AI path,
//   including the silent-fallback ones, which is the whole point.
//
// OUTCOME SEMANTICS  (agreed with the admin — do not change silently)
//   SUCCESS  a real provider returned hazards for the image.
//   FAILED   everything else, INCLUDING the offline / knowledge-bank fallback.
//            The fallback returns text, but the AI never saw the image; scoring
//            it as success would make a total outage read as a 100% pass rate.
//            failReason separates an outage ('no_internet') from a model
//            problem ('empty_result', 'providers_exhausted').
//   CACHED   an identical image had already been analysed. Counted separately
//            and EXCLUDED from all timing, because cache hits return in
//            milliseconds and would otherwise flatter the average badly.
//
// DESIGN
//   • Offline-first, like AiCorrectionService: write locally first, then
//     best-effort mirror to Supabase (table `ai_runs`).
//   • FIRE AND FORGET at every call site. Telemetry must never delay a scan or
//     turn a logging failure into a user-visible error, so record() swallows
//     everything and callers do not await it.
//   • No image bytes and no free text are stored — only a hash, counts,
//     timings, and the reporter identity the app already stores on incidents.

import 'dart:convert';
import 'package:flutter/foundation.dart'
    show kIsWeb, debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:shared_preferences/shared_preferences.dart';

import 'local_db.dart';
import 'supabase_service.dart';
import 'app_updater.dart';

class AiRunLog {
  AiRunLog._();

  // ── Run types ─────────────────────────────────────────────────────────────
  static const String typeHazardScan     = 'HAZARD_SCAN';
  static const String typeNearMissImage  = 'NEAR_MISS_IMAGE';
  static const String typeNearMissText   = 'NEAR_MISS_TEXT';
  static const String typeFieldRefine    = 'FIELD_REFINE';

  // ── Outcomes ──────────────────────────────────────────────────────────────
  static const String outcomeSuccess = 'SUCCESS';
  static const String outcomeFailed  = 'FAILED';
  static const String outcomeCached  = 'CACHED';

  // ── Fail reasons (short, stable codes so they group cleanly) ──────────────
  static const String reasonNoInternet    = 'no_internet';
  static const String reasonConcurrent    = 'concurrent';
  static const String reasonExhausted     = 'providers_exhausted';
  static const String reasonException     = 'exception';
  static const String reasonEmptyResult   = 'empty_result';
  static const String reasonTimeout       = 'timeout';

  /// Local ring buffer. Kept larger than ErrorLogService's 500 because one
  /// scan produces exactly one row and the admin wants a week of history, but
  /// still bounded — SharedPreferences holds this as a single JSON string and
  /// an unbounded list would grow the app's startup read forever.
  static const int _maxLocal = 1000;
  static const String _kRuns = 'ai_runs_log';

  /// Human-readable labels for the fail-reason codes, for the admin UI.
  static String reasonLabel(String code) {
    switch (code) {
      case reasonNoInternet:  return 'No internet';
      case reasonConcurrent:  return 'Another scan in progress';
      case reasonExhausted:   return 'All providers failed';
      case reasonException:   return 'Unexpected error';
      case reasonEmptyResult: return 'Returned no hazards';
      case reasonTimeout:     return 'Timed out';
      case '':                return 'Unspecified';
      default:                return code;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  RECORDING
  // ══════════════════════════════════════════════════════════════════════════

  /// Record one AI run. FIRE AND FORGET — never await this from a UI path.
  ///
  /// Everything is wrapped so a telemetry problem can never surface as a scan
  /// failure. That matters more than not losing a record: the user is standing
  /// in front of a hazard trying to report it.
  static Future<void> record({
    required String runType,
    required String outcome,
    String failReason = '',
    String provider = '',
    String model = '',
    int durationMs = 0,
    int hazardCount = 0,
    int confidence = 0,
    String imageHash = '',
    String plant = '',
    String dept = '',
  }) async {
    try {
      // Identity is read from the session rather than passed in, so call sites
      // stay one line and cannot forget it. Anonymous (not-signed-in) scans are
      // still recorded — the Near Miss and AI Scan tabs are reachable without
      // logging in, and those runs count towards model performance too.
      String userName = '';
      String userPno  = '';
      try {
        final u = await LocalDB.getCurrentUser();
        if (u != null) {
          userName = (u['name'] ?? u['username'] ?? '').toString();
          userPno  = (u['pno'] ?? '').toString();
        }
      } catch (_) {}

      final now = DateTime.now();
      final record = <String, dynamic>{
        // microsecond + outcome keeps ids unique even for two runs in the same
        // millisecond on different code paths.
        'id': '${now.microsecondsSinceEpoch}_$runType',
        'runType': runType,
        'outcome': outcome,
        'failReason': failReason,
        'provider': provider,
        'model': model,
        'durationMs': durationMs,
        'hazardCount': hazardCount,
        'confidence': confidence,
        'imageHash': imageHash,
        'plant': plant,
        'dept': dept,
        'userName': userName,
        'userPno': userPno,
        'appVersion': await _appVersion(),
        'platform': _platform(),
        // UTC for the same reason incidents use UTC: a local ISO string carries
        // no offset, so a timestamptz column reads it as UTC and every IST
        // timestamp lands 5h30m in the past — which would silently move runs
        // into the previous day and corrupt the "today" counts.
        'createdAt': now.toUtc().toIso8601String(),
      };

      await _saveLocal(record);

      // Best-effort mirror. No-op when Supabase is disabled or the table is
      // missing, so the dashboard degrades to local-only rather than breaking.
      try {
        await SupabaseService.upsertAiRun(record);
      } catch (_) {}
    } catch (e) {
      // Deliberately terminal: telemetry never escalates.
      debugPrint('[AiRunLog] record failed (ignored): $e');
    }
  }

  /// Convenience wrapper: derive the outcome from a GeminiVision result map.
  ///
  /// This centralises the "was it really successful?" question, which is easy
  /// to get wrong at each call site because the fallback map looks valid. A run
  /// counts as SUCCESS only when the AI actually saw the image (_isOnline true,
  /// _imageAnalysed not false) AND it returned at least one hazard.
  static Future<void> recordFromResult({
    required String runType,
    required Map<String, dynamic>? result,
    required int durationMs,
    String plant = '',
    String dept = '',
    String failReasonIfBad = reasonExhausted,
  }) async {
    if (result == null) {
      return record(
        runType: runType,
        outcome: outcomeFailed,
        failReason: reasonException,
        durationMs: durationMs,
        plant: plant,
        dept: dept,
      );
    }

    final provider = (result['_source'] ?? '').toString();
    final model    = (result['_model'] ?? '').toString();
    final hazards  = result['hazards'];
    final count    = hazards is List ? hazards.length : 0;
    final conf     = _toInt(result['confidence']);
    final hash     = (result['_imageHash'] ?? result['imageHash'] ?? '').toString();

    final fromCache = result['_fromCache'] == true;
    final online    = result['_isOnline'] == true;
    // _imageAnalysed is only set (to false) by the fallback path, so treat a
    // missing key as "yes, analysed" rather than defaulting to failure.
    final analysed  = result['_imageAnalysed'] != false;

    if (fromCache) {
      return record(
        runType: runType, outcome: outcomeCached,
        provider: provider, model: model,
        durationMs: durationMs, hazardCount: count, confidence: conf,
        imageHash: hash, plant: plant, dept: dept,
      );
    }

    final ok = online && analysed && count > 0;
    var reason = '';
    if (!ok) {
      final offlineReason = (result['_offline_reason'] ?? '').toString();
      if (!online || !analysed) {
        reason = _mapOfflineReason(offlineReason, failReasonIfBad);
      } else {
        // Provider answered but found nothing — a model quality signal, not an
        // outage, so it must not be lumped in with connectivity failures.
        reason = reasonEmptyResult;
      }
    }

    return record(
      runType: runType,
      outcome: ok ? outcomeSuccess : outcomeFailed,
      failReason: reason,
      provider: provider, model: model,
      durationMs: durationMs, hazardCount: count, confidence: conf,
      imageHash: hash, plant: plant, dept: dept,
    );
  }

  /// Translate GeminiVision's free-text `_offline_reason` into a stable code.
  /// The text is written for humans and changes; grouping a dashboard by it
  /// directly would fragment the counts.
  static String _mapOfflineReason(String raw, String fallback) {
    final r = raw.toLowerCase();
    if (r.contains('no internet') || r.contains('offline')) {
      return reasonNoInternet;
    }
    if (r.contains('another analysis')) return reasonConcurrent;
    if (r.contains('timeout') || r.contains('timed out')) return reasonTimeout;
    if (r.contains('unavailable') || r.contains('exhausted')) {
      return reasonExhausted;
    }
    if (r.isNotEmpty) return fallback;
    return fallback;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  READING  (admin panel only)
  // ══════════════════════════════════════════════════════════════════════════

  /// All runs, newest first. Merges Supabase (all devices — the whole point of
  /// the dashboard) with the local queue so an offline admin still sees data.
  static Future<List<Map<String, dynamic>>> getAllRuns() async {
    try {
      final remote = await SupabaseService.fetchAiRuns()
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
      if (remote.isNotEmpty) await _mergeLocal(remote);
    } catch (_) {
      // Ignore — local is the display source of truth.
    }
    final all = await _getLocal();
    all.sort((a, b) => (b['createdAt']?.toString() ?? '')
        .compareTo(a['createdAt']?.toString() ?? ''));
    return all;
  }

  /// Aggregate stats for the admin dashboard.
  ///
  /// [runs] is pre-fetched so the caller can compute several windows (today vs
  /// 7 days) without re-hitting the network.
  static Map<String, dynamic> computeStats(
    List<Map<String, dynamic>> runs, {
    DateTime? since,
  }) {
    final scoped = since == null
        ? runs
        : runs.where((r) {
            final t = DateTime.tryParse(r['createdAt']?.toString() ?? '');
            // A run with an unparseable timestamp is excluded from a windowed
            // view rather than counted, so it can't inflate "today".
            return t != null && !t.toLocal().isBefore(since);
          }).toList();

    var success = 0, failed = 0, cached = 0;
    final byReason   = <String, int>{};
    final byProvider = <String, int>{};
    final byType     = <String, int>{};
    final durations  = <int>[];        // SUCCESS only — see below
    var hazardTotal  = 0;
    var confTotal    = 0;

    for (final r in scoped) {
      final outcome = (r['outcome'] ?? '').toString();
      final type    = (r['runType'] ?? '').toString();
      byType[type] = (byType[type] ?? 0) + 1;

      switch (outcome) {
        case outcomeSuccess:
          success++;
          final d = _toInt(r['durationMs']);
          // Only successful, non-cached runs feed the timing figures. Including
          // failures would mean a fast failure (no internet, returns instantly)
          // *improved* the average response time — the opposite of the truth.
          if (d > 0) durations.add(d);
          hazardTotal += _toInt(r['hazardCount']);
          confTotal   += _toInt(r['confidence']);
          final p = (r['provider'] ?? '').toString();
          if (p.isNotEmpty) byProvider[p] = (byProvider[p] ?? 0) + 1;
          break;
        case outcomeCached:
          cached++;
          break;
        default:
          failed++;
          final reason = (r['failReason'] ?? '').toString();
          byReason[reason] = (byReason[reason] ?? 0) + 1;
      }
    }

    // Cache hits are excluded from the denominator too. They are neither a
    // model success nor a model failure — including them would let a warm cache
    // mask a broken provider.
    final attempted = success + failed;
    durations.sort();

    return {
      'total': scoped.length,
      'success': success,
      'failed': failed,
      'cached': cached,
      'attempted': attempted,
      'successRate': attempted == 0 ? 0.0 : (success * 100.0 / attempted),
      'avgMs': durations.isEmpty
          ? 0
          : (durations.reduce((a, b) => a + b) / durations.length).round(),
      'p95Ms': _percentile(durations, 0.95),
      'fastestMs': durations.isEmpty ? 0 : durations.first,
      'slowestMs': durations.isEmpty ? 0 : durations.last,
      'avgHazards': success == 0 ? 0.0 : hazardTotal / success,
      'avgConfidence': success == 0 ? 0.0 : confTotal / success,
      'byReason': byReason,
      'byProvider': byProvider,
      'byType': byType,
    };
  }

  /// Nearest-rank percentile on a pre-sorted list. Returns 0 when empty.
  static int _percentile(List<int> sorted, double p) {
    if (sorted.isEmpty) return 0;
    if (sorted.length == 1) return sorted.first;
    final idx = (p * (sorted.length - 1)).round();
    return sorted[idx.clamp(0, sorted.length - 1)];
  }

  /// CSV of the given runs, for offline analysis in Excel.
  static String exportToCsv(List<Map<String, dynamic>> runs) {
    const cols = [
      'createdAt', 'runType', 'outcome', 'failReason', 'provider', 'model',
      'durationMs', 'hazardCount', 'confidence', 'plant', 'dept',
      'userName', 'userPno', 'platform', 'appVersion', 'imageHash',
    ];
    final b = StringBuffer()..writeln(cols.join(','));
    for (final r in runs) {
      b.writeln(cols.map((c) => _csvEsc(r[c]?.toString() ?? '')).join(','));
    }
    return b.toString();
  }

  static String _csvEsc(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      final escaped = s.replaceAll('"', '""');
      return '"$escaped"';
    }
    return s;
  }

  /// Delete every stored run (local only — Supabase rows are kept as the
  /// system of record; clearing those should be a deliberate SQL action).
  static Future<void> clearLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kRuns);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  LOCAL STORE
  // ══════════════════════════════════════════════════════════════════════════
  //
  // Uses its own SharedPreferences handle rather than LocalDB, because
  // GeminiVision can run before LocalDB.init() on a cold start (the Near Miss
  // and AI Scan tabs are reachable without login) and LocalDB._prefs is a
  // `late` field that would throw if touched first.

  static Future<List<Map<String, dynamic>>> _getLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kRuns);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveLocal(Map<String, dynamic> run) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await _getLocal();
    all.add(run);
    // Trim oldest first. The list is append-ordered, so a plain sublist is
    // enough and avoids sorting 1000 entries on every scan.
    final trimmed =
        all.length > _maxLocal ? all.sublist(all.length - _maxLocal) : all;
    await prefs.setString(_kRuns, jsonEncode(trimmed));
  }

  static Future<void> _mergeLocal(List<Map<String, dynamic>> incoming) async {
    if (incoming.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = await _getLocal();
    final byId = <String, Map<String, dynamic>>{
      for (final r in all) (r['id']?.toString() ?? ''): r,
    };
    for (final r in incoming) {
      final id = r['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      byId[id] = {...?byId[id], ...r};
    }
    final merged = byId.values.toList()
      ..sort((a, b) => (a['createdAt']?.toString() ?? '')
          .compareTo(b['createdAt']?.toString() ?? ''));
    final trimmed = merged.length > _maxLocal
        ? merged.sublist(merged.length - _maxLocal)
        : merged;
    await prefs.setString(_kRuns, jsonEncode(trimmed));
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  ENVIRONMENT
  // ══════════════════════════════════════════════════════════════════════════

  static String? _cachedVersion;

  /// Real app version, not the hardcoded '1.0.98' string the existing error-log
  /// call sites pass — that literal is already two years of releases stale
  /// (releases are past 1.0.166), which would make version-correlated analysis
  /// meaningless.
  static Future<String> _appVersion() async {
    if (_cachedVersion != null) return _cachedVersion!;
    try {
      _cachedVersion = await AppUpdater.getCurrentVersion();
    } catch (_) {
      _cachedVersion = 'unknown';
    }
    return _cachedVersion!;
  }

  /// Platform without importing dart:io — this service is reachable from web
  /// builds, where Platform.isAndroid throws. (The same mistake broke an
  /// earlier build: `Platform.isAndroid` in a widely-imported file fails to
  /// compile for web.)
  static String _platform() {
    // kIsWeb must be checked FIRST: on web defaultTargetPlatform reports the
    // host OS (android on a phone browser), so reading it alone would label
    // browser sessions as native Android.
    if (kIsWeb) return 'Web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android: return 'Android';
      case TargetPlatform.iOS:     return 'iOS';
      case TargetPlatform.windows: return 'Windows';
      case TargetPlatform.macOS:   return 'macOS';
      case TargetPlatform.linux:   return 'Linux';
      default:                     return 'Other';
    }
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.round();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
