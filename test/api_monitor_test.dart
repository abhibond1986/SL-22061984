// Tests for client-side API/auth failure monitoring.
//
// Two properties are being protected here. The first is that the numbers mean
// something: the old `ErrorLogService.getSuccessRate` returned
// `((100 - errors.length) / 100) * 100`, which is not a rate because successes
// were never counted. The second is that nothing identifying is written to
// client-side storage — see the `recordAuthEvent` group.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safety_lens/services/api_monitor.dart';

void main() {
  setUp(ApiMonitor.resetForTest);

  group('ApiMonitor.classify', () {
    test('status codes win over exception text', () {
      expect(ApiMonitor.classify(null, statusCode: 429), FailureKind.rateLimited);
      expect(ApiMonitor.classify(null, statusCode: 401), FailureKind.auth);
      expect(ApiMonitor.classify(null, statusCode: 403), FailureKind.auth);
      expect(ApiMonitor.classify(null, statusCode: 500), FailureKind.server);
      expect(ApiMonitor.classify(null, statusCode: 503), FailureKind.server);
      expect(ApiMonitor.classify(null, statusCode: 422), FailureKind.rejected);
    });

    test('transport exceptions map to network or timeout', () {
      expect(ApiMonitor.classify(TimeoutException('x')), FailureKind.timeout);
      expect(ApiMonitor.classify(http.ClientException('XMLHttpRequest error.')),
          FailureKind.network);
      expect(ApiMonitor.classify(const SocketException('Failed host lookup: x')),
          FailureKind.network);
    });

    test('a truncated JSON body reads as a parse failure', () {
      expect(ApiMonitor.classify(const FormatException('Unexpected character')),
          FailureKind.parse);
    });

    test('nothing at all is unknown, not a false server error', () {
      expect(ApiMonitor.classify(null), FailureKind.unknown);
    });

    test('never throws, whatever the object does', () {
      // This runs on failure paths. A monitoring call that throws would replace
      // a recoverable network error with a crash — strictly worse than not
      // recording anything.
      expect(ApiMonitor.classify(_HostileError()), FailureKind.unknown);
    });
  });

  group('rates and counters', () {
    test('successRate stays null until there is enough traffic to mean anything',
        () {
      expect(ApiMonitor.successRate, isNull);
      for (var i = 0; i < 4; i++) {
        ApiMonitor.recordSuccess('appsScript', action: 'health');
      }
      expect(ApiMonitor.successRate, isNull);
      ApiMonitor.recordSuccess('appsScript', action: 'health');
      expect(ApiMonitor.successRate, 1.0);
    });

    test('successRate counts both sides', () {
      for (var i = 0; i < 8; i++) {
        ApiMonitor.recordSuccess('appsScript', action: 'health');
      }
      ApiMonitor.recordFailure('appsScript',
          action: 'health', kind: FailureKind.timeout);
      ApiMonitor.recordFailure('appsScript',
          action: 'health', kind: FailureKind.network);
      expect(ApiMonitor.failureCount, 2);
      expect(ApiMonitor.successRate, 0.8);
    });

    test('consecutiveFailures distinguishes "down now" from "was bad earlier"',
        () {
      ApiMonitor.recordFailure('appsScript', kind: FailureKind.server);
      ApiMonitor.recordFailure('appsScript', kind: FailureKind.server);
      expect(ApiMonitor.consecutiveFailures, 2);
      ApiMonitor.recordSuccess('appsScript');
      expect(ApiMonitor.consecutiveFailures, 0);
      expect(ApiMonitor.failureCount, 2, reason: 'history is still there');
    });

    test('a call that recovered is a success, with the retry still visible', () {
      ApiMonitor.recordRecovery('appsScript', action: 'health', attempts: 2);
      // The user got their answer, so counting this against the success rate
      // would make a flaky-but-working link look like an outage. The attempt
      // count is what surfaces the flakiness.
      expect(ApiMonitor.failureCount, 0);
      expect(ApiMonitor.snapshot()['recoveredAfterRetry'], 1);
    });
  });

  group('snapshot', () {
    test('buckets failures by kind and endpoint', () {
      ApiMonitor.recordFailure('appsScript',
          action: 'listUsers', kind: FailureKind.timeout);
      ApiMonitor.recordFailure('appsScript',
          action: 'listUsers', kind: FailureKind.timeout);
      ApiMonitor.recordFailure('supabase',
          action: 'fetchIncidents', kind: FailureKind.server);
      ApiMonitor.recordSuccess('appsScript', action: 'health');

      final snap = ApiMonitor.snapshot();
      expect(snap['total'], 4);
      expect(snap['failures'], 3);
      expect((snap['byKind'] as Map)[FailureKind.timeout], 2);
      expect((snap['byKind'] as Map)[FailureKind.server], 1);
      expect((snap['byEndpoint'] as Map)['appsScript'], 2);
      expect((snap['byEndpoint'] as Map)['supabase'], 1);
    });

    test('successes are not counted into the failure buckets', () {
      ApiMonitor.recordSuccess('appsScript', action: 'health');
      final snap = ApiMonitor.snapshot();
      expect(snap['failures'], 0);
      expect(snap['byKind'], isEmpty);
    });
  });

  group('recordAuthEvent', () {
    test('counts auth failures separately from API failures', () {
      ApiMonitor.recordAuthEvent(AuthFlow.signIn,
          ok: false, kind: FailureKind.auth);
      ApiMonitor.recordAuthEvent(AuthFlow.register, ok: true);
      ApiMonitor.recordFailure('appsScript', kind: FailureKind.server);

      final snap = ApiMonitor.snapshot();
      expect(snap['authFailures'], 1);
      expect(snap['failures'], 2);
    });

    test('keeps the flow identifiable', () {
      ApiMonitor.recordAuthEvent(AuthFlow.signIn, ok: false);
      expect(ApiMonitor.recent.single.endpoint, 'auth/signIn');
      expect(ApiMonitor.recent.single.action, AuthFlow.signIn);
    });

    test('records no account identity', () {
      // Deliberate: counting "3 sign-in failures in the last hour" is the useful
      // signal. Recording whose they were would turn localStorage into a list of
      // valid usernames for anyone holding the device.
      ApiMonitor.recordAuthEvent(AuthFlow.signIn,
          ok: false, kind: FailureKind.auth);
      final stored = ApiMonitor.recent.single.toJson().toString().toLowerCase();
      expect(stored.contains('@'), isFalse, reason: stored);
      expect(stored.contains('pno'), isFalse, reason: stored);
      expect(stored.contains('password'), isFalse, reason: stored);
    });

    test('a failure with no stated kind is still categorised', () {
      ApiMonitor.recordAuthEvent(AuthFlow.passwordChange, ok: false);
      expect(ApiMonitor.recent.single.kind, FailureKind.unknown);
    });

    test('a success carries no failure kind', () {
      ApiMonitor.recordAuthEvent(AuthFlow.signIn, ok: true);
      expect(ApiMonitor.recent.single.kind, isNull);
    });
  });

  group('persistence shape', () {
    test('an event round-trips through JSON', () {
      final ev = ApiEvent(
        at: DateTime.parse('2026-09-26T10:00:00.000Z'),
        endpoint: 'appsScript',
        action: 'health',
        ok: false,
        kind: FailureKind.timeout,
        statusCode: 504,
        attempts: 3,
        ms: 900,
      );
      final back = ApiEvent.tryFromJson(ev.toJson())!;
      expect(back.endpoint, 'appsScript');
      expect(back.action, 'health');
      expect(back.ok, isFalse);
      expect(back.kind, FailureKind.timeout);
      expect(back.statusCode, 504);
      expect(back.attempts, 3);
      expect(back.ms, 900);
      expect(back.at, ev.at);
    });

    test('a corrupt stored record is dropped rather than thrown on', () {
      // The store is localStorage on web, which other code and other app
      // versions can have written. A monitoring store that cannot be parsed must
      // not be the reason the app fails to start.
      expect(ApiEvent.tryFromJson(<String, dynamic>{'nonsense': 1}), isNull);
      expect(
          ApiEvent.tryFromJson(
              <String, dynamic>{'t': 'not a date', 'e': 'appsScript'}),
          isNull);
      expect(
          ApiEvent.tryFromJson(<String, dynamic>{'t': '2026-09-26T10:00:00Z'}),
          isNull,
          reason: 'no endpoint');
    });

    test('a record missing optional fields still loads', () {
      final back = ApiEvent.tryFromJson(<String, dynamic>{
        't': '2026-09-26T10:00:00.000Z',
        'e': 'appsScript',
        'ok': true,
      })!;
      expect(back.attempts, 1);
      expect(back.ms, 0);
      expect(back.kind, isNull);
    });
  });

  group('diagnostics plumbing', () {
    test('only failures wake a listening panel', () {
      final before = ApiMonitor.revision.value;
      ApiMonitor.recordSuccess('appsScript');
      expect(ApiMonitor.revision.value, before,
          reason: 'a healthy call must not cause a rebuild');
      ApiMonitor.recordFailure('appsScript', kind: FailureKind.server);
      expect(ApiMonitor.revision.value, greaterThan(before));
    });

    test('safeDetail redacts before anything is stored or shown', () {
      final out = ApiMonitor.safeDetail(
          Exception('POST https://script.google.com/macros/s/AKfyc/exec failed'));
      expect(out.contains('script.google.com'), isFalse, reason: out);
    });

    test('recent is not writable by callers', () {
      ApiMonitor.recordFailure('appsScript', kind: FailureKind.server);
      expect(() => ApiMonitor.recent.clear(), throwsUnsupportedError);
    });
  });
}

class _HostileError implements Exception {
  @override
  String toString() => throw StateError('toString itself throws');
}
