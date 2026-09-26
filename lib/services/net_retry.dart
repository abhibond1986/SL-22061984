// SAIL Safety Lens — network retry policy
//
// One place that decides *whether* a failed request may be tried again, and
// *how long* to wait before doing so. Before this existed the app had exactly
// one retry loop (`NetworkChecker.canReachBackend`, linear backoff, default
// maxRetries = 1, and not actually reachable from `getNetworkStatus()`), so in
// practice a single dropped packet on a plant Wi-Fi handover surfaced to the
// operator as a hard failure.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE IDEMPOTENCY RULE — read this before widening any policy below.
//
// Retrying a read costs a little time. Retrying a write can create a second
// incident record, a second user, a second corrective action. On a safety
// system that is worse than the original failure: duplicated incidents inflate
// the plant's numbers, split the audit trail across two IDs, and mean a
// supervisor can close one copy while the other stays open.
//
// A timeout does NOT tell us the server did nothing. `Future.timeout` gives up
// waiting; it does not cancel the request, and Apps Script may well have
// already written the row and be midway through its 302. So:
//
//   * Reads (`RetryClass.safe`)      — retry on transport errors, timeouts,
//                                      429 and 5xx. Worst case we read twice.
//   * Writes (`RetryClass.mutating`) — retry ONLY on failures that prove the
//                                      body never reached the server: a DNS
//                                      failure, a refused connection, or an
//                                      explicit 429 (rate-limited requests are
//                                      rejected before the handler runs).
//                                      Never on timeout. Never on 5xx.
//
// On web there is no way to distinguish "could not connect" from "connected,
// then the response was lost" — `package:http` collapses both into
// `ClientException: XMLHttpRequest error.`. So web writes get no retry at all.
// See `_neverSent`.
//
// Widening this to retry writes on timeout requires server-side idempotency
// first: the Apps Script handler must upsert on a client-generated request key
// rather than append. That is tracked as an open item, not assumed here.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'api_monitor.dart';
import 'app_logger.dart';

/// How dangerous it is to run a request twice.
enum RetryClass {
  /// Reading, pinging, or any operation the server treats as idempotent.
  safe,

  /// Creates or changes server state. Retried only when provably never sent.
  mutating,
}

/// The outcome of a retried call, so callers can tell "failed once" from
/// "failed after we genuinely tried".
class RetryOutcome<T> {
  final T? value;
  final int attempts;
  final Object? error;

  /// The last result that came back over the wire even though it was judged
  /// retryable — a 503 HTML page from the Apps Script front end, say.
  ///
  /// Exists so exhausting the retries does not throw away information the
  /// caller already had before retrying was introduced: callers of
  /// `_postWithRedirect` branch on `resp.statusCode`, and handing them `null`
  /// where they used to get a 503 would quietly reclassify "backend refused" as
  /// "no network".
  final T? lastTransportValue;

  const RetryOutcome({
    this.value,
    required this.attempts,
    this.error,
    this.lastTransportValue,
  });

  bool get ok => error == null;
}

class NetRetry {
  /// Apps Script actions known to be side-effect free.
  ///
  /// Deliberately an allow-list, not a deny-list: a new action added to the
  /// backend defaults to [RetryClass.mutating] and is therefore safe, whereas a
  /// deny-list would silently opt every new write into retrying.
  /// Names are the wire values the Apps Script router switches on, not the Dart
  /// method names — `SyncService.pullKbDocs` posts `action: 'listKnowledge'`.
  ///
  /// Two absences are deliberate:
  ///   * `login` — a rejected sign-in may advance a server-side lockout counter,
  ///     so replaying it could lock an operator out of a safety system three
  ///     times faster than they earned.
  ///   * `gemini` — metered. Retrying spends quota, and a second inference on
  ///     the same photo can return a different hazard set, which is the last
  ///     thing an auditable analysis needs.
  static const Set<String> _readOnlyActions = <String>{
    'health',
    'listUsers',
    'listIncidents',
    'listKnowledge',
    'getMasterData',
    'getAiKeys',
  };

  static RetryClass classifyAction(String? action) {
    if (action == null || action.isEmpty) return RetryClass.mutating;
    return _readOnlyActions.contains(action)
        ? RetryClass.safe
        : RetryClass.mutating;
  }

  // ── Backoff shape ─────────────────────────────────────────────────────────

  static const Duration _baseDelay = Duration(milliseconds: 400);
  static const Duration _maxDelay = Duration(seconds: 4);
  static final Random _rng = Random();

  /// Equal jitter: half the exponential delay, plus a random share of the other
  /// half. Full jitter would sometimes retry almost instantly, which defeats
  /// the point when the cause is a saturated link; no jitter at all makes every
  /// client in the plant retry in lockstep after a backend blip and produces
  /// the thundering herd that caused the 429 in the first place.
  static Duration delayForAttempt(int attempt) {
    final exp = _baseDelay.inMilliseconds * pow(2, attempt - 1).toInt();
    final capped = min(exp, _maxDelay.inMilliseconds);
    final half = capped ~/ 2;
    return Duration(milliseconds: half + _rng.nextInt(half + 1));
  }

  // ── Failure classification ────────────────────────────────────────────────

  // `SocketException` and `HandshakeException` live in `dart:io`, which cannot
  // be imported at all in a Flutter Web build — a bare `import 'dart:io'` here
  // would break the primary target for the sake of a type test. Matching on the
  // runtime type name keeps one file that compiles everywhere. The alternative,
  // a conditional-import shim pair, is three files and a stub for something
  // that only ever needs the name.
  static String _typeName(Object error) => error.runtimeType.toString();

  /// True only for failures that prove the request body never reached the
  /// server, so replaying it cannot duplicate anything.
  static bool _neverSent(Object error) {
    // No equivalent signal exists in the browser: a CORS rejection, an offline
    // adapter and a response lost after the write all arrive as the same
    // ClientException. Refusing to guess is the whole safety margin here.
    if (kIsWeb) return false;
    if (_typeName(error) != 'SocketException') return false;
    final m = error.toString().toLowerCase();
    return m.contains('failed host lookup') ||
        m.contains('connection refused') ||
        m.contains('network is unreachable') ||
        m.contains('no route to host');
  }

  /// Transport-level failure of any kind — nothing usable came back.
  static bool _isTransport(Object error) {
    if (error is http.ClientException) return true;
    if (error is TimeoutException) return true;
    final t = _typeName(error);
    return t == 'SocketException' ||
        t == 'HandshakeException' ||
        t == 'HttpException';
  }

  static bool shouldRetry({
    required Object? error,
    required int? statusCode,
    required RetryClass retryClass,
  }) {
    // 429 is the one status that is unambiguous for both classes: the request
    // was rejected by the quota gate before the handler could touch state.
    if (statusCode == 429) return true;

    if (retryClass == RetryClass.mutating) {
      return error != null && _neverSent(error);
    }

    if (statusCode != null) {
      // 5xx and the Apps Script "try again" statuses only. A 4xx means we sent
      // something the server disagrees with — replaying it verbatim will fail
      // identically and just burns the user's time.
      return statusCode >= 500 && statusCode <= 599;
    }
    return error != null && _isTransport(error);
  }

  // ── Runner ────────────────────────────────────────────────────────────────

  /// Runs [attempt] up to [maxAttempts] times with exponential backoff.
  ///
  /// [attempt] receives the 1-based attempt number and the per-attempt timeout
  /// it should use. It must either return a value or throw.
  ///
  /// [statusOf] lets HTTP callers expose the status code of a *successful*
  /// transport round-trip that nevertheless needs retrying (a 503 page from the
  /// Apps Script front end arrives as a normal `http.Response`, not an
  /// exception, so without this hook every backend hiccup would look like a
  /// success carrying an HTML body).
  ///
  /// [budget] is a hard ceiling on total elapsed time including backoff waits.
  /// By default attempts *share* it rather than each getting the caller's full
  /// timeout: `pushIncident` already asks for 30 s, and three untrimmed attempts
  /// plus waits would have left an operator staring at a spinner for 95 s. The
  /// existing wall-clock envelope is the contract the screens were built
  /// against, and retries are not worth widening it.
  ///
  /// [attemptTimeout] opts out of that division and gives every attempt the
  /// same window. Use it only where the retryable failures are known to be
  /// near-instant — [RetryClass.mutating] qualifies, because the sole condition
  /// that lets a write be replayed is a connection that was refused or a host
  /// that did not resolve, neither of which consumes the clock. That keeps
  /// writes at exactly their previous per-attempt timeout, so adding retry here
  /// cannot make a slow-but-working save start failing.
  static Future<RetryOutcome<T>> run<T>({
    required String label,
    required Future<T> Function(int attempt, Duration timeout) attempt,
    required RetryClass retryClass,
    required Duration budget,
    Duration? attemptTimeout,
    int maxAttempts = 3,
    int? Function(T value)? statusOf,
    String? action,
  }) async {
    final deadline = DateTime.now().add(budget);
    // Reserve room for the backoff waits so the last attempt is not handed a
    // timeout of a few milliseconds and made to fail for the wrong reason.
    final perAttempt = attemptTimeout ??
        Duration(
            milliseconds: max(2000, budget.inMilliseconds ~/ maxAttempts));

    Object? lastError;
    T? lastValue;
    var tries = 0;

    for (var i = 1; i <= maxAttempts; i++) {
      tries = i;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;

      final thisTimeout =
          remaining < perAttempt ? remaining : perAttempt;

      try {
        final value = await attempt(i, thisTimeout);
        final status = statusOf == null ? null : statusOf(value);
        if (status == null ||
            !shouldRetry(
                error: null, statusCode: status, retryClass: retryClass)) {
          if (i > 1) {
            ApiMonitor.recordRecovery(label, action: action, attempts: i);
          }
          return RetryOutcome<T>(value: value, attempts: i);
        }
        lastValue = value;
        lastError = _HttpStatusFailure(status);
      } catch (e) {
        lastError = e;
        if (!shouldRetry(
            error: e, statusCode: null, retryClass: retryClass)) {
          // Deliberately not logged as an error here — the caller owns the
          // user-facing outcome and logging it twice made the admin log read as
          // if every failure happened two or three times.
          return RetryOutcome<T>(
              attempts: i, error: e, lastTransportValue: lastValue);
        }
      }

      if (i == maxAttempts) break;

      final wait = delayForAttempt(i);
      if (DateTime.now().add(wait).isAfter(deadline)) break;
      AppLogger.debug(
        'NetRetry',
        '$label attempt $i failed, retrying in ${wait.inMilliseconds}ms',
        action: action,
      );
      await Future<void>.delayed(wait);
    }

    return RetryOutcome<T>(
        attempts: tries,
        error: lastError ?? _HttpStatusFailure(null),
        lastTransportValue: lastValue);
  }
}

/// Stands in for "the round trip worked but the status says try again", so the
/// runner has a single error channel.
class _HttpStatusFailure implements Exception {
  final int? statusCode;
  const _HttpStatusFailure(this.statusCode);

  @override
  String toString() => statusCode == null
      ? 'Request failed with no response'
      : 'Request failed with HTTP $statusCode';
}
