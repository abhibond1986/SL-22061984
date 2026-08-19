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

import 'dart:async';
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
  /// One OCR pass over one scanned SOP page.
  static const String typeSopOcr         = 'SOP_OCR';
  /// The single structuring pass over a whole scanned document's text.
  static const String typeSopSummary     = 'SOP_SUMMARY';

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

  /// Local-only bookkeeping key on each stored record: has this run reached
  /// Supabase yet? It is deliberately NOT in SupabaseService._runAppToDb, so it
  /// is stripped before upload and can never break the insert.
  ///
  /// WHY THIS EXISTS — this is the bug that made the dashboard read zero.
  /// record() mirrored to Supabase exactly once, inside `try { } catch (_) {}`.
  /// If that single attempt failed — offline, or, far more likely, because
  /// supabase_ai_runs_setup.sql had not been run yet so the `ai_runs` table did
  /// not exist — the run stayed in this device's SharedPreferences and was never
  /// retried. The dashboard then showed those runs on the device that produced
  /// them and NOTHING anywhere else, because the whole point of the panel
  /// ("every AI analysis run across all devices") depends on the mirror. Open
  /// the same panel from another device, another browser profile, or a web build
  /// with a fresh localStorage, and you get a clean set of zeros for runs that
  /// definitely happened. Marking sync state and retrying fixes that
  /// permanently, and retroactively: the backlog uploads as soon as the table
  /// exists, so nothing recorded during the outage is lost.
  static const String _kSynced = 'synced';

  /// Serialises every read-modify-write of the runs list.
  ///
  /// _saveLocal reads the whole JSON blob, appends, and writes it back. record()
  /// is fire-and-forget from several call sites, so two runs finishing close
  /// together could both read the same snapshot and the second write would
  /// silently discard the first run. The lock makes appends atomic.
  static Future<void> _writeChain = Future<void>.value();

  /// Queues [action] behind any write already in flight. Every mutation below
  /// goes through this, so the read-modify-write is never interleaved.
  static Future<void> _locked(Future<void> Function() action) {
    final out = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        await action();
        if (!out.isCompleted) out.complete();
      } catch (e, st) {
        if (!out.isCompleted) out.completeError(e, st);
      }
    });
    return out.future;
  }

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
        // Pessimistic until proven otherwise, so a crash between the local
        // write and the upload leaves the run queued rather than assumed sent.
        _kSynced: false,
      };

      await _saveLocal(record);

      // Best-effort mirror. Unlike before, a failure is REMEMBERED: the record
      // keeps synced=false and flushUnsynced() will retry it on the next app
      // start, background sync, or dashboard open.
      try {
        final ok = await SupabaseService.upsertAiRun(record);
        if (ok) await _markSynced({record['id'].toString()});
      } catch (_) {}
    } catch (e) {
      // Deliberately terminal: telemetry never escalates.
      debugPrint('[AiRunLog] record failed (ignored): $e');
    }
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  READING  (admin panel only)
  // ══════════════════════════════════════════════════════════════════════════

  /// Number of runs recorded on this device that have not reached Supabase yet.
  /// Shown in the dashboard so a broken mirror is visible instead of looking
  /// like an empty week.
  static Future<int> pendingUploadCount() async {
    final all = await _getLocal();
    return all.where(_isUnsynced).length;
  }

  static bool _isUnsynced(Map<String, dynamic> r) => r[_kSynced] != true;

  /// Rows the server returned on the last getAllRuns(). Reported verbatim by the
  /// dashboard, because "how many runs does the cloud actually hold" is the one
  /// number that tells an admin the mirror is working — and it cannot be derived
  /// from the local list, which is capped at [_maxLocal] while the server keeps
  /// far more.
  static int lastRemoteCount = 0;

  /// Trim to [_maxLocal], but never evict a run that has not been uploaded yet.
  ///
  /// A blind "keep the newest 1000" would quietly delete the very backlog this
  /// class exists to protect: _mergeLocal folds in up to 5000 server rows, so on
  /// a device where reads succeed but writes fail (read-only RLS, for instance)
  /// the unsynced records would be trimmed away and pendingUploadCount() would
  /// fall to 0 — a green "all synced" banner over permanently missing runs.
  static List<Map<String, dynamic>> _trim(List<Map<String, dynamic>> all) {
    if (all.length <= _maxLocal) return all;
    final unsynced = all.where(_isUnsynced).toList();
    if (unsynced.length >= _maxLocal) return unsynced;
    // Fill the remaining budget with the newest synced rows, then restore
    // chronological order so later appends stay append-ordered.
    final synced = all.where((r) => !_isUnsynced(r)).toList();
    final keep = synced.sublist(synced.length - (_maxLocal - unsynced.length));
    final out = [...unsynced, ...keep]
      ..sort((a, b) => (a['createdAt']?.toString() ?? '')
          .compareTo(b['createdAt']?.toString() ?? ''));
    return out;
  }

  /// Upload every run that has not reached Supabase yet, oldest first.
  ///
  /// Safe and cheap to call often: it returns immediately when there is nothing
  /// pending or Supabase is not ready, and the upsert is keyed on `id`, so a
  /// retry that partly succeeded before cannot create duplicates.
  ///
  /// Returns the number of runs successfully uploaded.
  static Future<int> flushUnsynced({int batchSize = 200}) async {
    try {
      if (!SupabaseService.isReady) return 0;
      final all = await _getLocal();
      final pending = all.where(_isUnsynced).toList()
        ..sort((a, b) => (a['createdAt']?.toString() ?? '')
            .compareTo(b['createdAt']?.toString() ?? ''));
      if (pending.isEmpty) return 0;

      var sent = 0;
      for (var i = 0; i < pending.length; i += batchSize) {
        final end =
            (i + batchSize) < pending.length ? i + batchSize : pending.length;
        final chunk = pending.sublist(i, end);
        final confirmed = await SupabaseService.upsertAiRuns(chunk);
        if (confirmed.isNotEmpty) {
          // Only ids the server echoed back are marked — see upsertAiRuns.
          await _markSynced(confirmed);
          sent += confirmed.length;
          continue;
        }
        // Nothing confirmed. Stop only if the CLOUD is the problem, so the
        // backlog is preserved for the next attempt. An empty error means the
        // chunk itself was unsendable (no usable ids), which must not block the
        // remaining chunks forever.
        if (SupabaseService.aiRunsLastError.isNotEmpty ||
            SupabaseService.aiRunsCloudDisabled) break;
      }
      if (sent > 0) debugPrint('[AiRunLog] flushed $sent pending run(s)');
      return sent;
    } catch (e) {
      debugPrint('[AiRunLog] flushUnsynced failed (ignored): $e');
      return 0;
    }
  }

  /// All runs, newest first. Merges Supabase (all devices — the whole point of
  /// the dashboard) with the local queue so an offline admin still sees data.
  ///
  /// Kicks the local backlog on the way past, so opening the dashboard is also
  /// what repairs a previously failed mirror. Deliberately NOT awaited: when the
  /// table is missing, the upload burns its full timeout before failing, and
  /// awaiting it would leave the admin staring at a spinner for ~25s in exactly
  /// the broken state this panel exists to diagnose. The Retry button awaits.
  static Future<List<Map<String, dynamic>>> getAllRuns() async {
    flushUnsynced().catchError((_) => 0);
    try {
      final remote = await SupabaseService.fetchAiRuns()
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
      lastRemoteCount = remote.length;
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

  static Future<void> _saveLocal(Map<String, dynamic> run) => _locked(() async {
        final prefs = await SharedPreferences.getInstance();
        final all = await _getLocal();
        all.add(run);
        await prefs.setString(_kRuns, jsonEncode(_trim(all)));
      });

  /// Flip the local sync flag for the given run ids after a successful upload.
  static Future<void> _markSynced(Set<String> ids) => _locked(() async {
        if (ids.isEmpty) return;
        final prefs = await SharedPreferences.getInstance();
        final all = await _getLocal();
        var changed = false;
        for (final r in all) {
          if (ids.contains(r['id']?.toString() ?? '') && r[_kSynced] != true) {
            r[_kSynced] = true;
            changed = true;
          }
        }
        if (changed) await prefs.setString(_kRuns, jsonEncode(all));
      });

  static Future<void> _mergeLocal(List<Map<String, dynamic>> incoming) =>
      _locked(() async {
        if (incoming.isEmpty) return;
        final prefs = await SharedPreferences.getInstance();
        final all = await _getLocal();
        final byId = <String, Map<String, dynamic>>{
          for (final r in all) (r['id']?.toString() ?? ''): r,
        };
        for (final r in incoming) {
          final id = r['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          // A row that came back FROM the server is by definition synced — set
          // the flag last so it wins over a stale local false and the row is not
          // re-uploaded forever.
          byId[id] = {...?byId[id], ...r, _kSynced: true};
        }
        final merged = byId.values.toList()
          ..sort((a, b) => (a['createdAt']?.toString() ?? '')
              .compareTo(b['createdAt']?.toString() ?? ''));
        await prefs.setString(_kRuns, jsonEncode(_trim(merged)));
      });

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
