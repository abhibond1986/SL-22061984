// Tests for the retry policy.
//
// The assertions that matter most here are the negative ones. Anyone can make a
// request try again; the job of this class is to refuse to try again when doing
// so could write a second incident record. If you are relaxing a rule below,
// read the header of lib/services/net_retry.dart first — each `!shouldRetry`
// case is deliberate, not an oversight.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:safety_lens/services/net_retry.dart';

void main() {
  group('NetRetry.classifyAction', () {
    test('known read actions are safe to repeat', () {
      for (final a in ['health', 'listUsers', 'listIncidents', 'listKnowledge',
        'getMasterData', 'getAiKeys']) {
        expect(NetRetry.classifyAction(a), RetryClass.safe, reason: a);
      }
    });

    test('writes are mutating', () {
      for (final a in ['addIncident', 'addKnowledge', 'saveMasterData',
        'deleteUser', 'deleteIncident', 'updateRole', 'register',
        'uploadPdfToDrive']) {
        expect(NetRetry.classifyAction(a), RetryClass.mutating, reason: a);
      }
    });

    test('login is mutating even though it reads', () {
      // A rejected sign-in can advance a server-side lockout counter, so three
      // automatic replays would lock an operator out of a safety system three
      // times faster than they earned it.
      expect(NetRetry.classifyAction('login'), RetryClass.mutating);
    });

    test('gemini is mutating even though it reads', () {
      // Metered, and a second inference on the same photo can return a
      // different hazard set — not something an auditable analysis can absorb.
      expect(NetRetry.classifyAction('gemini'), RetryClass.mutating);
    });

    test('an action nobody has classified yet defaults to mutating', () {
      // The allow-list is the safety property: a new backend action must not
      // become retryable just because someone forgot to think about it.
      expect(NetRetry.classifyAction('someActionAddedNextYear'),
          RetryClass.mutating);
      expect(NetRetry.classifyAction(null), RetryClass.mutating);
      expect(NetRetry.classifyAction(''), RetryClass.mutating);
    });
  });

  group('NetRetry.shouldRetry', () {
    test('429 is retryable for reads and writes alike', () {
      // The one unambiguous status: the quota gate rejects the request before
      // the handler can touch any state.
      for (final c in RetryClass.values) {
        expect(
            NetRetry.shouldRetry(error: null, statusCode: 429, retryClass: c),
            isTrue,
            reason: '$c');
      }
    });

    test('5xx is retryable for reads only', () {
      expect(
          NetRetry.shouldRetry(
              error: null, statusCode: 503, retryClass: RetryClass.safe),
          isTrue);
      expect(
          NetRetry.shouldRetry(
              error: null, statusCode: 503, retryClass: RetryClass.mutating),
          isFalse);
    });

    test('4xx is never retryable — replaying it fails identically', () {
      for (final s in [400, 401, 403, 404, 409, 422]) {
        expect(
            NetRetry.shouldRetry(
                error: null, statusCode: s, retryClass: RetryClass.safe),
            isFalse,
            reason: 'HTTP $s');
      }
    });

    test('2xx and 3xx are not retryable', () {
      for (final s in [200, 201, 204, 301, 302]) {
        expect(
            NetRetry.shouldRetry(
                error: null, statusCode: s, retryClass: RetryClass.safe),
            isFalse,
            reason: 'HTTP $s');
      }
    });

    test('a timeout is retryable for a read', () {
      expect(
          NetRetry.shouldRetry(
              error: TimeoutException('slow'),
              statusCode: null,
              retryClass: RetryClass.safe),
          isTrue);
    });

    test('a timeout is NOT retryable for a write', () {
      // The single most important assertion in this file. `Future.timeout` gives
      // up waiting; it does not cancel the request. Apps Script may already have
      // appended the row and be midway through its 302. Retrying here is how you
      // get two incident records for one event, split audit trails, and a
      // supervisor closing one copy while the other stays open.
      expect(
          NetRetry.shouldRetry(
              error: TimeoutException('slow'),
              statusCode: null,
              retryClass: RetryClass.mutating),
          isFalse);
    });

    test('a browser transport failure is retryable for a read only', () {
      final e = http.ClientException('XMLHttpRequest error.');
      expect(
          NetRetry.shouldRetry(
              error: e, statusCode: null, retryClass: RetryClass.safe),
          isTrue);
      // On web, a CORS rejection, an offline adapter and a response lost after
      // the write all arrive as this same exception. There is no signal to
      // distinguish them, so a write does not get to guess.
      expect(
          NetRetry.shouldRetry(
              error: e, statusCode: null, retryClass: RetryClass.mutating),
          isFalse);
    });

    test('a write IS retried when the body provably never left', () {
      for (final m in [
        'Failed host lookup: script.google.com',
        'Connection refused',
        'Network is unreachable',
        'No route to host',
      ]) {
        expect(
            NetRetry.shouldRetry(
                error: SocketException(m),
                statusCode: null,
                retryClass: RetryClass.mutating),
            isTrue,
            reason: m);
      }
    });

    test('a write is NOT retried on a mid-flight socket failure', () {
      // "Reset by peer" means bytes were already on the wire. That is exactly
      // the ambiguous case the policy refuses.
      expect(
          NetRetry.shouldRetry(
              error: const SocketException('Connection reset by peer'),
              statusCode: null,
              retryClass: RetryClass.mutating),
          isFalse);
    });

    test('an unrecognised error is not retried', () {
      expect(
          NetRetry.shouldRetry(
              error: const FormatException('not JSON'),
              statusCode: null,
              retryClass: RetryClass.safe),
          isFalse);
    });
  });

  group('NetRetry.delayForAttempt', () {
    test('attempt 1 lands in the equal-jitter band above the 400ms base', () {
      var lo = 1 << 30, hi = 0;
      for (var i = 0; i < 200; i++) {
        final ms = NetRetry.delayForAttempt(1).inMilliseconds;
        expect(ms, greaterThanOrEqualTo(200));
        expect(ms, lessThanOrEqualTo(400));
        if (ms < lo) lo = ms;
        if (ms > hi) hi = ms;
      }
      // Jitter has to actually jitter: without it every client in the plant
      // retries in lockstep after a backend blip and re-creates the 429 that
      // caused the retry.
      expect(hi, greaterThan(lo));
    });

    test('never exceeds the 4s cap, however many attempts', () {
      for (var i = 1; i <= 20; i++) {
        final ms = NetRetry.delayForAttempt(i).inMilliseconds;
        expect(ms, greaterThan(0), reason: 'attempt $i');
        expect(ms, lessThanOrEqualTo(4000), reason: 'attempt $i');
      }
    });

    test('grows before it saturates', () {
      // Compare medians rather than single draws, since each is jittered.
      int median(int attempt) {
        final xs = List<int>.generate(
            51, (_) => NetRetry.delayForAttempt(attempt).inMilliseconds)
          ..sort();
        return xs[25];
      }

      expect(median(3), greaterThan(median(1)));
      expect(median(5), greaterThanOrEqualTo(median(3)));
    });
  });

  group('NetRetry.run', () {
    test('a transient read failure recovers and reports the attempt count',
        () async {
      var calls = 0;
      final out = await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(seconds: 10),
        attempt: (n, t) async {
          calls++;
          if (n < 3) throw http.ClientException('boom');
          return 'ok';
        },
      );
      expect(out.ok, isTrue);
      expect(out.value, 'ok');
      expect(out.attempts, 3);
      expect(calls, 3);
    });

    test('a timed-out write is attempted exactly once', () async {
      var calls = 0;
      final out = await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.mutating,
        budget: const Duration(seconds: 10),
        attempt: (n, t) async {
          calls++;
          throw TimeoutException('the row may already be written');
        },
      );
      expect(calls, 1);
      expect(out.ok, isFalse);
      expect(out.error, isA<TimeoutException>());
    });

    test('a persistent 503 exhausts the attempts but keeps the response',
        () async {
      var calls = 0;
      final out = await NetRetry.run<http.Response>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(seconds: 10),
        statusOf: (r) => r.statusCode,
        attempt: (n, t) async {
          calls++;
          return http.Response('<html>busy</html>', 503);
        },
      );
      expect(calls, 3);
      expect(out.ok, isFalse);
      // Callers branch on statusCode. Handing back null where they used to get a
      // 503 would silently reclassify "backend refused" as "no network", which
      // is the one distinction the operator actually needs.
      expect(out.lastTransportValue?.statusCode, 503);
    });

    test('a non-retryable error stops on the first attempt', () async {
      var calls = 0;
      final out = await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(seconds: 10),
        attempt: (n, t) async {
          calls++;
          throw const FormatException('not JSON');
        },
      );
      expect(calls, 1);
      expect(out.ok, isFalse);
    });

    test('a 200 short-circuits the loop', () async {
      var calls = 0;
      final out = await NetRetry.run<http.Response>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(seconds: 10),
        statusOf: (r) => r.statusCode,
        attempt: (n, t) async {
          calls++;
          return http.Response('{}', 200);
        },
      );
      expect(calls, 1);
      expect(out.ok, isTrue);
    });

    test('the budget bounds total wall time even if every attempt hangs',
        () async {
      final started = DateTime.now();
      final out = await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(milliseconds: 1200),
        attempt: (n, t) => Future<String>.delayed(
            const Duration(seconds: 30), () => 'too late').timeout(t),
      );
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 4)));
      expect(out.ok, isFalse);
      expect(out.attempts, greaterThanOrEqualTo(1));
    });

    test('a read attempt gets budget / maxAttempts', () async {
      Duration? seen;
      await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(seconds: 30),
        attempt: (n, t) async {
          seen = t;
          return 'ok';
        },
      );
      // Reads share the caller's timeout so the wall-clock envelope the screens
      // were built against does not widen.
      expect(seen, const Duration(seconds: 10));
    });

    test('a write attempt keeps the caller\'s full timeout', () async {
      Duration? seen;
      await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.mutating,
        budget: const Duration(seconds: 35),
        attemptTimeout: const Duration(seconds: 30),
        maxAttempts: 2,
        attempt: (n, t) async {
          seen = t;
          return 'ok';
        },
      );
      // Adding retry must not make a slow-but-working save start failing, so a
      // write's first attempt is handed exactly the window it had before.
      expect(seen, const Duration(seconds: 30));
    });

    test('the per-attempt timeout is floored rather than shrinking to zero',
        () async {
      // A 1-second budget over 3 attempts would otherwise hand attempt 3 a few
      // hundred milliseconds and fail it for the wrong reason.
      Duration? seen;
      await NetRetry.run<String>(
        label: 'test',
        retryClass: RetryClass.safe,
        budget: const Duration(seconds: 1),
        attempt: (n, t) async {
          seen = t;
          return 'ok';
        },
      );
      expect(seen, isNotNull);
      expect(seen!.inMilliseconds, greaterThan(100));
    });
  });
}
