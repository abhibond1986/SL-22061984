// lib/services/startup_diagnostics.dart
//
// Startup instrumentation, safe error presentation, and support reference IDs.
//
// WHY THIS EXISTS
// ---------------
// Before this file, a failure during app startup produced a permanently blank
// screen. `main()` awaited six initialisers with no timeout and no try/catch, so
// a single hanging or throwing call meant `runApp()` was never reached — the user
// sat on "Initializing…" forever with no message, no retry and nothing a support
// desk could act on. There was also no `runZonedGuarded`, `FlutterError.onError`
// or `ErrorWidget.builder` anywhere in `lib/`.
//
// This class provides the three things that were missing:
//
//   1. `guard()`  — run a startup step with a hard deadline, so no single step
//                   can stall first paint. A failed step degrades the feature it
//                   belongs to instead of killing the app.
//   2. `sanitize()` — turn an arbitrary exception into something safe to show a
//                   plant employee: no URLs, no keys, no stack traces, no
//                   database internals.
//   3. `newReferenceId()` — a short code the user can read aloud to support,
//                   which we can correlate with the detailed local log.
//
// It deliberately does NOT replace `AppLogger` (structured per-source logging,
// 200-entry ring buffer, persisted at error level and above) or
// `ErrorLogService` (backend-pushed AI/system failures). It layers on top:
// everything recorded here is also handed to `AppLogger`, so the admin
// diagnostics view keeps working with no changes.
//
// DESIGN CONSTRAINT: this file must stay importable on web. That rules out
// `dart:io`, so error classification is done on the exception's string form and
// runtime type name rather than with `is SocketException` checks.

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, kDebugMode, visibleForTesting;

import 'app_logger.dart';

/// Outcome of a single instrumented startup step.
class StartupStep {
  final String name;
  final int durationMs;
  final bool ok;

  /// True when the step exceeded its deadline rather than throwing. Worth
  /// distinguishing: a timeout usually means a blocked network, whereas a throw
  /// usually means a genuine defect or an unavailable platform channel.
  final bool timedOut;

  /// Sanitised reason. Never contains a stack trace, URL or credential.
  final String? reason;

  const StartupStep({
    required this.name,
    required this.durationMs,
    required this.ok,
    this.timedOut = false,
    this.reason,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'ms': durationMs,
        'ok': ok,
        if (timedOut) 'timedOut': true,
        if (reason != null) 'reason': reason,
      };

  @override
  String toString() =>
      '$name ${durationMs}ms ${ok ? "ok" : (timedOut ? "TIMEOUT" : "FAILED")}'
      '${reason == null ? "" : " — $reason"}';
}

class StartupDiagnostics {
  StartupDiagnostics._();

  /// Set as early as possible in `main()`, before any awaits.
  static DateTime? _processStart;

  /// Wall-clock ms from the first line of `main()` to the first rendered frame.
  static int? _firstFrameMs;

  static final List<StartupStep> _steps = <StartupStep>[];

  /// Reference ID for the current session. Generated lazily on first failure so
  /// a healthy session does not manufacture a support code nobody needs.
  static String? _sessionRef;

  static final Random _rand = Random();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  static void begin() {
    _processStart ??= DateTime.now();
  }

  /// Call from the first frame callback. Idempotent — only the first call counts,
  /// because later frames are not "startup" and would overwrite a good number.
  static void markFirstFrame() {
    if (_firstFrameMs != null || _processStart == null) return;
    _firstFrameMs = DateTime.now().difference(_processStart!).inMilliseconds;
    AppLogger.info(
      'Startup',
      'First frame in ${_firstFrameMs}ms '
          '(${_steps.where((s) => !s.ok).length} of ${_steps.length} steps degraded)',
      action: 'startup',
    );
    if (kDebugMode) {
      for (final s in _steps) {
        debugPrint('  · $s');
      }
    }
  }

  static int? get firstFrameMs => _firstFrameMs;

  /// Clears all accumulated static state.
  ///
  /// Tests only. This class is intentionally static — it has to be reachable
  /// from `main()` before any object graph exists — which means state survives
  /// between test cases in the same file. Without this, a test that adopts a
  /// reference ID silently changes the meaning of every later assertion about
  /// one, and those tests then pass for the wrong reason.
  @visibleForTesting
  static void resetForTest() {
    _processStart = null;
    _firstFrameMs = null;
    _sessionRef = null;
    _steps.clear();
  }

  static List<StartupStep> get steps => List.unmodifiable(_steps);

  static bool get hadFailures => _steps.any((s) => !s.ok);

  /// Steps that did not complete, for the "running in limited mode" banner.
  static List<String> get degradedSteps =>
      _steps.where((s) => !s.ok).map((s) => s.name).toList();

  // ── Bounded step runner ───────────────────────────────────────────────────

  /// Runs [action] with a hard [timeout], recording the outcome.
  ///
  /// Never rethrows: a startup step failing must not prevent `runApp()`. Returns
  /// [fallback] on timeout or error so the caller can carry on in a degraded
  /// state.
  ///
  /// IMPORTANT — `Future.timeout` does NOT cancel the underlying operation; it
  /// only stops *us* waiting. The original future keeps running, and if it later
  /// completes or throws, that throw would surface as an unhandled async error.
  /// `onLateCompletion` exists so callers can still observe a late success (for
  /// example marking Supabase initialised if it eventually connects), and the
  /// `.catchError` below absorbs a late failure rather than letting it escape
  /// into the zone handler and look like a fresh crash.
  static Future<T> guard<T>(
    String name,
    Future<T> Function() action, {
    required Duration timeout,
    required T fallback,
    void Function(T value)? onLateCompletion,
  }) async {
    final started = DateTime.now();
    final completer = Completer<T>();
    Future<T>? pending;

    try {
      pending = action();
    } catch (e, st) {
      // A synchronous throw before the first await inside `action`.
      _record(name, started, ok: false, error: e, stack: st);
      return fallback;
    }

    var settled = false;

    pending.then((value) {
      if (settled) {
        // Landed after we gave up. Let the caller salvage it if it can.
        _noteLateCompletion(name, started);
        if (onLateCompletion != null) {
          try {
            onLateCompletion(value);
          } catch (_) {/* a salvage path must not throw */}
        }
        return;
      }
      settled = true;
      // Release the caller BEFORE recording. Everything in `_record` is
      // bookkeeping — logging, redaction, string formatting — and none of it is
      // worth the risk of a defect in there leaving this completer uncompleted,
      // which would reproduce the exact unbounded-await hang this class exists
      // to prevent. Complete first; report second.
      completer.complete(value);
      _record(name, started, ok: true);
    }).catchError((Object e, StackTrace st) {
      if (settled) {
        // Late failure of an already-abandoned step. Already reported as a
        // timeout; swallow so it does not double-report as a crash.
        AppLogger.warn(
          'Startup',
          'Step "$name" failed after it had already timed out',
          details: sanitizeVerbose(e),
          action: 'startup',
        );
        return;
      }
      settled = true;
      completer.complete(fallback); // see note above: complete first
      _record(name, started, ok: false, error: e, stack: st);
    });

    // The deadline.
    Future<void>.delayed(timeout).then((_) {
      if (settled) return;
      settled = true;
      completer.complete(fallback); // see note above: complete first
      _record(name, started, ok: false, timedOut: true);
    });

    return completer.future;
  }

  /// Convenience wrapper for steps that return nothing.
  static Future<void> guardVoid(
    String name,
    Future<void> Function() action, {
    required Duration timeout,
  }) =>
      guard<bool>(
        name,
        () async {
          await action();
          return true;
        },
        timeout: timeout,
        fallback: false,
      );

  static void _record(
    String name,
    DateTime started, {
    required bool ok,
    bool timedOut = false,
    Object? error,
    StackTrace? stack,
  }) {
    final ms = DateTime.now().difference(started).inMilliseconds;
    final reason = timedOut
        ? 'Timed out after ${ms}ms'
        : (error == null ? null : sanitizeVerbose(error));

    _steps.add(StartupStep(
      name: name,
      durationMs: ms,
      ok: ok,
      timedOut: timedOut,
      reason: reason,
    ));

    if (ok) return;

    // A degraded startup step is a warning, not a crash: the app still runs.
    // Reserve `error`/`critical` for things that actually broke.
    AppLogger.warn(
      'Startup',
      'Step "$name" ${timedOut ? "timed out" : "failed"} after ${ms}ms',
      details: reason,
      action: 'startup',
    );
  }

  static void _noteLateCompletion(String name, DateTime started) {
    final ms = DateTime.now().difference(started).inMilliseconds;
    AppLogger.info(
      'Startup',
      'Step "$name" completed late (${ms}ms) — after startup had moved on',
      action: 'startup',
    );
  }

  // ── Support reference IDs ─────────────────────────────────────────────────

  /// Short, human-readable, telephone-friendly code: `SL-260926-K4F9`.
  ///
  /// Deliberately not a UUID. This gets read aloud over a noisy plant phone
  /// line, so it avoids ambiguous characters (O/0, I/1/L) and stays short enough
  /// to write on a notepad. It is a correlation handle, not a secret — it
  /// carries no user or device identity, so it is safe to display and safe to
  /// send in a support email.
  static String newReferenceId() {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no O/0/I/1/L
    final now = DateTime.now();
    final date = '${now.year % 100}'.padLeft(2, '0') +
        '${now.month}'.padLeft(2, '0') +
        '${now.day}'.padLeft(2, '0');
    final suffix =
        List.generate(4, (_) => alphabet[_rand.nextInt(alphabet.length)]).join();
    return 'SL-$date-$suffix';
  }

  /// One reference per session, reused so a user reporting several symptoms
  /// gives support a single code that ties the whole session together.
  static String get sessionReference {
    _sessionRef ??= newReferenceId();
    return _sessionRef!;
  }

  /// Matches the format produced by [newReferenceId] and by the boot script in
  /// `web/index.html`: `SL-` + 6 digits + `-` + 4 chars from the unambiguous
  /// alphabet.
  static final RegExp _refPattern =
      RegExp(r'^SL-\d{6}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$');

  /// Adopts the reference ID the web boot script already generated, so the
  /// support code the user saw on the HTML timeout screen matches the one the
  /// Dart side reports for the rest of the session.
  ///
  /// [raw] comes from `SharedPreferences.getString('sl_boot_ref')` — see the
  /// handoff comment in `web/index.html`. Returns silently without adopting
  /// anything if the value is absent (always the case on mobile), malformed, or
  /// still JSON-quoted by a plugin encoding we did not anticipate. Validating
  /// rather than trusting is the point: a bad value must cost us nothing, and it
  /// keeps an attacker-controllable localStorage key from injecting arbitrary
  /// text into a support-facing string.
  static void adoptBootReference(String? raw) {
    if (_sessionRef != null) return; // never overwrite an in-use reference
    if (raw == null) return;
    final cleaned = raw.replaceAll('"', '').trim();
    if (!_refPattern.hasMatch(cleaned)) return;
    _sessionRef = cleaned;
  }

  // ── Safe error presentation ───────────────────────────────────────────────

  // Secrets. Never acceptable anywhere — user-visible text, the verbose form,
  // the persisted log, the admin export. A leaked bearer token is as bad in a
  // local log file as it is on screen.
  //
  // Split out from the locator patterns below so a stack trace can be stripped
  // of credentials while keeping its frames: applying the whole list to a stack
  // replaced every `package:safety_lens/...` line with `[redacted]`, which made
  // the persisted trace worthless for diagnosis while protecting nothing a user
  // could not learn by reading the shipped JS.
  static final List<RegExp> _secretRedactions = <RegExp>[
    // JWTs (the Supabase anon/service keys are JWTs).
    RegExp(r'\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b'),
    // Any URL, which would otherwise expose project refs and internal hosts.
    // Triple-quoted raw string rather than adjacent-string concatenation: the
    // character class has to contain both quote characters, and splicing three
    // literals to achieve that is how this line was silently unterminated before.
    RegExp(r'''https?://[^\s"')\]]+'''),
    // Google API keys.
    RegExp(r'\bAIza[0-9A-Za-z_\-]{20,}\b'),
    // OpenRouter / OpenAI style keys.
    RegExp(r'\bsk-[A-Za-z0-9_\-]{16,}\b'),
    // Bearer/apikey headers echoed into an exception message.
    // NOTE: `caseSensitive: false`, NOT an inline `(?i)` group. Dart's RegExp is
    // ECMAScript-flavoured and throws FormatException on inline modifiers — and
    // because this list is a lazily-initialised `static final`, that throw would
    // fire from inside the error-reporting path and stall startup for good.
    // The `(?:bearer\s+)?` group is load-bearing: without it `Authorization:
    // Bearer <token>` matched only up to the word "Bearer" and left the actual
    // token in plain sight. The separator is optional so a bare `Bearer abc123`
    // with no header name is caught too.
    RegExp(
        r'\b(bearer|apikey|api[_\-]?key|authorization|token)\b'
        r'\s*[:=]?\s*(?:bearer\s+)?\S+',
        caseSensitive: false),
    // Long hex blobs — password hashes and salts.
    RegExp(r'\b[0-9a-fA-F]{32,}\b'),
  ];

  // Not secrets, but not for users either: absolute source paths name the build
  // machine's directory layout and, in a developer's case, their account name.
  // Stripped from anything a user or an API response can see, kept in the local
  // stack traces where they are the entire point.
  static final List<RegExp> _locatorRedactions = <RegExp>[
    // Windows source paths from stack traces.
    RegExp(r'''[A-Za-z]:\\[^\s"']+'''),
    // No leading \b here: a path is usually preceded by a space, and space→'/'
    // is not a word boundary, so the match would start after the first segment
    // and leak it (`at /home[redacted]`).
    RegExp(r'(?:/[\w.\-]+){2,}\.dart\b'),
  ];

  static final List<RegExp> _redactions = <RegExp>[
    ..._secretRedactions,
    ..._locatorRedactions,
  ];

  static String _apply(List<RegExp> patterns, String input) {
    var out = input;
    for (final re in patterns) {
      out = out.replaceAll(re, '[redacted]');
    }
    return out;
  }

  static String _redact(String input) => _apply(_redactions, input);

  /// Public, total form of the redactor, so anything that writes text to
  /// client-side storage or a console can share this one pattern list rather
  /// than growing a second, weaker copy. Used by `AppLogger` before it persists
  /// error details to SharedPreferences.
  ///
  /// This closes an import cycle with `app_logger.dart`. That is safe here:
  /// neither file reads state from the other at load time, and `_redactions` is
  /// a lazily-initialised `static final`, so there is no initialisation order to
  /// get wrong. The alternative — a third file holding the patterns — would
  /// split the one list that must not drift.
  static String redact(String input) {
    try {
      return _redact(input);
    } catch (_) {
      // Same reasoning as sanitizeVerbose: this runs on failure paths, and a
      // throwing redactor must degrade to withholding rather than to leaking.
      return '[unavailable]';
    }
  }

  /// Secrets only — keeps file paths intact.
  ///
  /// For stack traces heading into the local log, where the frames are the
  /// diagnostic value and the build machine's directory layout is not worth
  /// destroying them over. Never use this for anything a user sees; use
  /// [sanitize] for that and [redact] for everything else.
  static String redactSecrets(String input) {
    try {
      return _apply(_secretRedactions, input);
    } catch (_) {
      // Same reasoning as sanitizeVerbose: this runs on failure paths, and a
      // throwing redactor must degrade to withholding rather than to leaking.
      return '[unavailable]';
    }
  }

  /// Detailed-but-redacted form. For local logs and admin export — NOT for
  /// end users. Keeps the exception type and message so a developer can
  /// diagnose, but strips credentials, URLs and file paths.
  static String sanitizeVerbose(Object error) {
    // Total. This runs on the failure path — inside error handlers, inside
    // `_record`, inside `ErrorWidget.builder` — so it is the one function in the
    // codebase that genuinely must not be able to throw. A malformed pattern
    // here once cost a permanently blank app, and `error.toString()` is itself
    // arbitrary user code that can throw. When in doubt, say nothing rather than
    // risk leaking the unredacted text.
    try {
      var text = error.toString();
      if (text.length > 400) text = '${text.substring(0, 400)}…';
      return _redact(text);
    } catch (_) {
      return '[unavailable]';
    }
  }

  /// User-facing message. Says what the person can DO, not what broke.
  ///
  /// Intentionally coarse. The brief requires that errors never expose secrets,
  /// internal URLs, stack traces or database information, and the reliable way
  /// to guarantee that is to never interpolate the exception into user-visible
  /// copy at all — only map it to one of a fixed set of vetted sentences. The
  /// detail still reaches support via the reference ID.
  static const String genericFailure = 'Something went wrong. Please try again.';

  static String sanitize(Object error) {
    String t;
    try {
      t = error.toString().toLowerCase();
    } catch (_) {
      // `toString()` is arbitrary user code. If even that fails we still owe the
      // user a sentence.
      return genericFailure;
    }
    final type = error.runtimeType.toString().toLowerCase();

    final isTimeout = error is TimeoutException ||
        type.contains('timeout') ||
        t.contains('timed out') ||
        t.contains('timeout');
    if (isTimeout) {
      return 'The server took too long to respond. Please check your connection '
          'and try again.';
    }

    final isNetwork = type.contains('socket') ||
        type.contains('clientexception') ||
        type.contains('handshake') ||
        t.contains('failed host lookup') ||
        t.contains('connection refused') ||
        t.contains('connection closed') ||
        t.contains('network is unreachable') ||
        t.contains('xmlhttprequest');
    if (isNetwork) {
      return 'Cannot reach the SafetyLens server. Your work is saved on this '
          'device and will sync when you are back online.';
    }

    final isAuth = type.contains('authexception') ||
        t.contains('invalid login') ||
        t.contains('jwt') ||
        t.contains('unauthorized') ||
        t.contains('permission denied') ||
        t.contains('row-level security');
    if (isAuth) {
      return 'You do not have permission to do that, or your session has '
          'expired. Please sign in again.';
    }

    final isStorage = type.contains('quotaexceeded') ||
        t.contains('quota') ||
        t.contains('no space left');
    if (isStorage) {
      return 'This device is out of storage space. Please free some space and '
          'try again.';
    }

    // Anything unrecognised gets the generic sentence. Never the raw message.
    return genericFailure;
  }

  // ── Telemetry snapshot ────────────────────────────────────────────────────

  /// Snapshot for the admin diagnostics view and for support tickets.
  /// Contains no user identity, no credentials and no URLs by construction.
  static Map<String, dynamic> report() => {
        'reference': _sessionRef, // null when nothing has failed
        'platform': kIsWeb ? 'web' : 'native',
        'firstFrameMs': _firstFrameMs,
        'degraded': degradedSteps,
        'steps': _steps.map((s) => s.toJson()).toList(),
      };
}
