// SAIL Safety Lens — client-side monitoring for API and auth failures
//
// Answers the question an admin actually asks after a bad shift: "was it the
// network, the backend, or the app?" Before this, the pieces to answer it were
// scattered and mostly unwired — `AppLogger.errorCount` was session-only and no
// UI read it; `ErrorLogService.getErrorStats` shaped a per-endpoint failure
// count but had only two call sites, both in AI screens; `getSuccessRate`
// returned `((100 - errors.length) / 100) * 100`, which is not a success rate
// because successes were never counted at all.
//
// This class counts both sides, so the ratio means something.
//
// WHAT IS DELIBERATELY NOT STORED
//   No usernames, no P.no, no passwords, no request or response bodies, no
//   URLs, no tokens. A failure record is: which logical endpoint, which
//   category of failure, an HTTP status if there was one, attempt count, and a
//   timestamp. Free-text error strings are passed through the same redaction
//   used by StartupDiagnostics before they are kept, and only ever the short
//   form. This is a browser-resident store under the project rule that no
//   sensitive operational data lives in client-side storage, so the safe
//   default is to record a *classification* rather than a message.
//
//   Auth events record the flow name and the failure category only — never
//   which account was involved. Counting "3 sign-in failures in the last hour"
//   is the useful signal; recording whose they were would turn localStorage
//   into a list of valid usernames for anyone with the device.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'startup_diagnostics.dart';

/// Coarse failure categories. Kept small on purpose: these are for triage, and
/// a taxonomy with thirty entries is one nobody reads.
class FailureKind {
  static const String timeout = 'timeout';
  static const String network = 'network';
  static const String server = 'server';
  static const String rateLimited = 'rate_limited';
  static const String auth = 'auth';
  static const String parse = 'parse';
  static const String rejected = 'rejected';
  static const String unknown = 'unknown';
}

/// Auth flows worth distinguishing. A spike in `register` failures means
/// something different from a spike in `signIn`.
class AuthFlow {
  static const String signIn = 'signIn';
  static const String register = 'register';
  static const String passwordChange = 'passwordChange';
  static const String sessionRestore = 'sessionRestore';
}

class ApiEvent {
  final DateTime at;
  final String endpoint;
  final String? action;
  final bool ok;
  final String? kind;
  final int? statusCode;
  final int attempts;
  final int ms;

  const ApiEvent({
    required this.at,
    required this.endpoint,
    required this.ok,
    this.action,
    this.kind,
    this.statusCode,
    this.attempts = 1,
    this.ms = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': at.toIso8601String(),
        'e': endpoint,
        if (action != null) 'a': action,
        'ok': ok,
        if (kind != null) 'k': kind,
        if (statusCode != null) 's': statusCode,
        'n': attempts,
        'ms': ms,
      };

  static ApiEvent? tryFromJson(Map<String, dynamic> j) {
    final t = DateTime.tryParse(j['t']?.toString() ?? '');
    final e = j['e']?.toString();
    if (t == null || e == null) return null;
    return ApiEvent(
      at: t,
      endpoint: e,
      action: j['a']?.toString(),
      ok: j['ok'] == true,
      kind: j['k']?.toString(),
      statusCode: j['s'] is int ? j['s'] as int : null,
      attempts: j['n'] is int ? j['n'] as int : 1,
      ms: j['ms'] is int ? j['ms'] as int : 0,
    );
  }
}

class ApiMonitor {
  static const String _kEvents = 'api_monitor_events';
  static const int _maxEvents = 300;
  static const Duration _window = Duration(hours: 24);

  static final List<ApiEvent> _events = <ApiEvent>[];
  static SharedPreferences? _prefs;
  static bool _loaded = false;

  /// Bumped whenever a failure is recorded, so a diagnostics panel can rebuild
  /// without polling. Uses ValueNotifier rather than a stream because there is
  /// no dispose point for a static stream controller in this app.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Loads the persisted window. Safe to call more than once and safe to skip
  /// entirely — recording works before `init`, it just is not durable yet.
  static Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_kEvents);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final item in list) {
        if (item is Map) {
          final ev = ApiEvent.tryFromJson(Map<String, dynamic>.from(item));
          if (ev != null) _events.add(ev);
        }
      }
      _prune();
    } catch (_) {
      // A corrupt monitoring store must never be the reason the app fails to
      // start. Drop it and carry on with an empty window.
      _events.clear();
    }
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  static void recordSuccess(String endpoint,
      {String? action, int attempts = 1, int ms = 0}) {
    _add(ApiEvent(
      at: DateTime.now(),
      endpoint: endpoint,
      action: action,
      ok: true,
      attempts: attempts,
      ms: ms,
    ));
  }

  static void recordFailure(String endpoint,
      {String? action,
      required String kind,
      int? statusCode,
      int attempts = 1,
      int ms = 0}) {
    _add(ApiEvent(
      at: DateTime.now(),
      endpoint: endpoint,
      action: action,
      ok: false,
      kind: kind,
      statusCode: statusCode,
      attempts: attempts,
      ms: ms,
    ));
  }

  /// A call that failed at least once and then succeeded. Recorded as a success
  /// with `attempts > 1` rather than as a failure: the user got their answer, so
  /// counting it against the success rate would make a healthy-but-flaky link
  /// look like an outage. The attempt count is what surfaces the flakiness.
  static void recordRecovery(String endpoint,
      {String? action, required int attempts}) {
    _add(ApiEvent(
      at: DateTime.now(),
      endpoint: endpoint,
      action: action,
      ok: true,
      attempts: attempts,
    ));
  }

  /// Sign-in, registration and password-change outcomes.
  ///
  /// The account is never part of the record — see the note at the top of this
  /// file. `flow` is one of the [AuthFlow] constants.
  static void recordAuthEvent(String flow,
      {required bool ok, String? kind, int? statusCode}) {
    _add(ApiEvent(
      at: DateTime.now(),
      endpoint: 'auth/$flow',
      action: flow,
      ok: ok,
      kind: ok ? null : (kind ?? FailureKind.unknown),
      statusCode: statusCode,
    ));
  }

  static void _add(ApiEvent ev) {
    _events.add(ev);
    _prune();
    if (!ev.ok) {
      revision.value++;
    }
    _persist();
  }

  static void _prune() {
    final cutoff = DateTime.now().subtract(_window);
    _events.removeWhere((e) => e.at.isBefore(cutoff));
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
  }

  static bool _persistScheduled = false;

  /// Coalesced write. A failing sync can record a dozen events in a second and
  /// each one re-encoding 300 records to localStorage was measurable on low-end
  /// Android browsers, so writes are batched to one per turn of the event loop.
  static void _persist() {
    if (_prefs == null || _persistScheduled) return;
    _persistScheduled = true;
    Future<void>.microtask(() async {
      _persistScheduled = false;
      try {
        await _prefs!.setString(
            _kEvents, jsonEncode(_events.map((e) => e.toJson()).toList()));
      } catch (_) {
        // Monitoring is best-effort by definition.
      }
    });
  }

  // ── Classification ────────────────────────────────────────────────────────

  /// Maps a thrown object to a [FailureKind].
  ///
  /// Total: this runs on failure paths, and a monitoring call that throws would
  /// replace a recoverable network error with a crash.
  static String classify(Object? error, {int? statusCode}) {
    try {
      if (statusCode != null) {
        if (statusCode == 429) return FailureKind.rateLimited;
        if (statusCode == 401 || statusCode == 403) return FailureKind.auth;
        if (statusCode >= 500) return FailureKind.server;
        if (statusCode >= 400) return FailureKind.rejected;
      }
      if (error == null) {
        return statusCode == null ? FailureKind.unknown : FailureKind.server;
      }
      final t = error.runtimeType.toString();
      if (t == 'TimeoutException') return FailureKind.timeout;
      if (t == 'SocketException' ||
          t == 'ClientException' ||
          t == 'HandshakeException') {
        return FailureKind.network;
      }
      if (t == 'FormatException') return FailureKind.parse;

      final m = error.toString().toLowerCase();
      if (m.contains('timeout') || m.contains('timed out')) {
        return FailureKind.timeout;
      }
      if (m.contains('xmlhttprequest') ||
          m.contains('failed to fetch') ||
          m.contains('failed host lookup') ||
          m.contains('socketexception') ||
          m.contains('network')) {
        return FailureKind.network;
      }
      if (m.contains('unauthor') ||
          m.contains('forbidden') ||
          m.contains('invalid credential')) {
        return FailureKind.auth;
      }
      if (m.contains('unexpected character') || m.contains('formatexception')) {
        return FailureKind.parse;
      }
      return FailureKind.unknown;
    } catch (_) {
      return FailureKind.unknown;
    }
  }

  /// Short, redacted form of an error for the local diagnostics list. Never
  /// shown to end users — [StartupDiagnostics.sanitize] is for that.
  static String safeDetail(Object error) =>
      StartupDiagnostics.sanitizeVerbose(error);

  // ── Reading ───────────────────────────────────────────────────────────────

  static List<ApiEvent> get recent => List<ApiEvent>.unmodifiable(_events);

  static int get failureCount => _events.where((e) => !e.ok).length;

  /// Consecutive failures at the tail of the window — the signal for "the
  /// backend is down right now" as opposed to "we had a bad patch earlier".
  static int get consecutiveFailures {
    var n = 0;
    for (var i = _events.length - 1; i >= 0; i--) {
      if (_events[i].ok) break;
      n++;
    }
    return n;
  }

  /// A real success rate over the window: successes / total, or null when there
  /// is not enough traffic for the number to mean anything.
  static double? get successRate {
    if (_events.length < 5) return null;
    final ok = _events.where((e) => e.ok).length;
    return ok / _events.length;
  }

  static Map<String, dynamic> snapshot() {
    final byKind = <String, int>{};
    final byEndpoint = <String, int>{};
    var retried = 0;
    for (final e in _events) {
      if (!e.ok) {
        final k = e.kind ?? FailureKind.unknown;
        byKind[k] = (byKind[k] ?? 0) + 1;
        byEndpoint[e.endpoint] = (byEndpoint[e.endpoint] ?? 0) + 1;
      }
      if (e.attempts > 1) retried++;
    }
    final authFailures = _events
        .where((e) => !e.ok && e.endpoint.startsWith('auth/'))
        .length;
    return <String, dynamic>{
      'windowHours': _window.inHours,
      'total': _events.length,
      'failures': failureCount,
      'authFailures': authFailures,
      'consecutiveFailures': consecutiveFailures,
      'recoveredAfterRetry': retried,
      'successRate': successRate,
      'byKind': byKind,
      'byEndpoint': byEndpoint,
    };
  }

  @visibleForTesting
  static void resetForTest() {
    _events.clear();
    _prefs = null;
    _loaded = false;
    _persistScheduled = false;
    revision.value = 0;
  }
}
