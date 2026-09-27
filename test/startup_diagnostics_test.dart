// test/startup_diagnostics_test.dart
//
// Covers the three guarantees StartupDiagnostics is responsible for:
//   1. guard() never hangs past its deadline and never rethrows
//   2. sanitize()/sanitizeVerbose() never leak credentials, URLs or paths
//   3. reference IDs are well-formed, and adopted ones are validated
//
// Guarantee 2 is the one worth testing hardest. The brief requires that errors
// never expose secrets, internal URLs, stack traces or database information, and
// that is a claim about every possible input — so these tests use the real shapes
// that appear in this codebase (the Supabase anon JWT, Google AIza keys, Windows
// source paths, 64-char password hashes) rather than toy strings.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/services/startup_diagnostics.dart';

void main() {
  // StartupDiagnostics is static by necessity (main() needs it before any object
  // graph exists), so state leaks between cases unless it is cleared. Without
  // this, the "adopts a valid reference" case below would leave _sessionRef set
  // and every later reference assertion would pass without exercising anything.
  setUp(StartupDiagnostics.resetForTest);

  group('guard — deadlines', () {
    test('returns the value when the action completes in time', () async {
      final result = await StartupDiagnostics.guard<int>(
        'fast',
        () async => 42,
        timeout: const Duration(seconds: 1),
        fallback: -1,
      );
      expect(result, 42);
    });

    test('returns the fallback instead of hanging when the action stalls',
        () async {
      final sw = Stopwatch()..start();
      final result = await StartupDiagnostics.guard<int>(
        'stalls forever',
        // A future that never completes — the exact shape of the original
        // Supabase.initialize hang this class exists to contain.
        () => Completer<int>().future,
        timeout: const Duration(milliseconds: 120),
        fallback: -1,
      );
      sw.stop();

      expect(result, -1, reason: 'must fall back rather than wait');
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: 'must not outlast its deadline');
    });

    test('returns the fallback when the action throws asynchronously', () async {
      final result = await StartupDiagnostics.guard<int>(
        'async throw',
        () async => throw StateError('boom'),
        timeout: const Duration(seconds: 1),
        fallback: -1,
      );
      expect(result, -1);
    });

    test('returns the fallback when the action throws synchronously', () async {
      // Distinct code path: this throws before the first await, so the exception
      // escapes before there is any future to attach a handler to.
      final result = await StartupDiagnostics.guard<int>(
        'sync throw',
        () => throw StateError('boom'),
        timeout: const Duration(seconds: 1),
        fallback: -1,
      );
      expect(result, -1);
    });

    test('a late completion after timeout does not escape as an unhandled error',
        () async {
      // Regression guard for the subtle half of Future.timeout: it stops us
      // waiting but does NOT cancel the operation. If the abandoned future later
      // throws and nobody is listening, it surfaces in runZonedGuarded and looks
      // like a fresh crash. guard() must absorb it.
      final completer = Completer<int>();

      final result = await StartupDiagnostics.guard<int>(
        'late failure',
        () => completer.future,
        timeout: const Duration(milliseconds: 50),
        fallback: -1,
      );
      expect(result, -1);

      completer.completeError(StateError('arrived too late'));
      // Let the microtask queue drain. If the error escaped, the zone this test
      // runs in fails the test.
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });

    test('onLateCompletion lets a caller salvage a slow success', () async {
      // This is how SupabaseService recovers mid-session: the init we gave up on
      // eventually connects, and the client becomes usable without a restart.
      final completer = Completer<bool>();
      var salvaged = false;

      await StartupDiagnostics.guard<bool>(
        'late success',
        () => completer.future,
        timeout: const Duration(milliseconds: 50),
        fallback: false,
        onLateCompletion: (value) => salvaged = value,
      );

      completer.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(salvaged, isTrue);
    });

    test('records a degraded step so the UI can report limited mode', () async {
      await StartupDiagnostics.guard<int>(
        'recorded failure',
        () async => throw StateError('boom'),
        timeout: const Duration(seconds: 1),
        fallback: 0,
      );
      expect(StartupDiagnostics.degradedSteps, contains('recorded failure'));
      expect(StartupDiagnostics.hadFailures, isTrue);
    });
  });

  group('sanitize — user-facing copy', () {
    test('maps a timeout to actionable advice', () {
      final msg = StartupDiagnostics.sanitize(TimeoutException('x'));
      expect(msg, contains('took too long'));
    });

    test('maps a network failure and reassures that work is not lost', () {
      final msg = StartupDiagnostics.sanitize(
          Exception('Failed host lookup: mptdergmcakhufsmcogd.supabase.co'));
      expect(msg, contains('Cannot reach'));
      expect(msg, contains('saved on this device'));
    });

    test('maps an RLS rejection to a permission message', () {
      final msg = StartupDiagnostics.sanitize(
          Exception('new row violates row-level security policy for "app_users"'));
      expect(msg, contains('permission'));
    });

    test('never echoes the underlying exception text', () {
      // The whole point: user-visible copy is chosen from a fixed vetted set, so
      // no input can steer what is displayed.
      final leaky = Exception(
          'PostgrestException: relation "app_users" does not exist, '
          'hint: check schema public, key=AIzaSyTESTTESTTESTTESTTESTTEST123456');
      final msg = StartupDiagnostics.sanitize(leaky);

      expect(msg, isNot(contains('app_users')));
      expect(msg, isNot(contains('AIza')));
      expect(msg, isNot(contains('Postgrest')));
      expect(msg, isNot(contains('schema')));
    });

    test('unrecognised errors fall through to the generic sentence', () {
      expect(StartupDiagnostics.sanitize(Exception('totally novel problem')),
          StartupDiagnostics.genericFailure);
    });
  });

  group('sanitizeVerbose — redaction for logs and admin export', () {
    test('redacts a Supabase-style JWT', () {
      // Same shape as the anon key hardcoded in SupabaseConfig.
      const jwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSJ9.'
          'zkK7JSvp6AJ1JiVqCjd130f9PwS4412VygPhGX1ga4Y';
      final out = StartupDiagnostics.sanitizeVerbose(Exception('auth $jwt'));
      expect(out, isNot(contains('eyJhbGci')));
      expect(out, contains('[redacted]'));
    });

    test('redacts URLs so project refs and internal hosts do not leak', () {
      final out = StartupDiagnostics.sanitizeVerbose(
          Exception('POST https://mptdergmcakhufsmcogd.supabase.co/rest/v1/incidents failed'));
      expect(out, isNot(contains('supabase.co')));
      expect(out, isNot(contains('mptdergmcakhufsmcogd')));
    });

    test('redacts Google and OpenRouter style API keys', () {
      final out = StartupDiagnostics.sanitizeVerbose(Exception(
          'AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ012345 and sk-abcdefghijklmnopqrstuvwxyz'));
      expect(out, isNot(contains('AIzaSy')));
      expect(out, isNot(contains('sk-abcdef')));
    });

    test('redacts an authorization header echoed into a message', () {
      final out = StartupDiagnostics.sanitizeVerbose(
          Exception('headers: {apikey: somesecretvalue123456}'));
      expect(out, isNot(contains('somesecretvalue')));
    });

    test('redacts header names case-insensitively', () {
      // Real headers arrive capitalised. This pattern originally used an inline
      // `(?i)` group, which Dart's RegExp rejects outright — so the whole
      // redaction list threw on construction and no redaction happened at all.
      for (final line in <String>[
        'Authorization: Bearer abcdefghijklmnop',
        'APIKEY=somesecretvalue123456',
        'Api-Key: somesecretvalue123456',
        'Bearer abcdefghijklmnop',
      ]) {
        final out = StartupDiagnostics.sanitizeVerbose(Exception(line));
        expect(out, isNot(contains('somesecretvalue')), reason: line);
        expect(out, isNot(contains('abcdefghijklmnop')), reason: line);
      }
    });

    test('redacts Windows source paths from stack-trace-like text', () {
      final out = StartupDiagnostics.sanitizeVerbose(
          Exception(r'at C:\Users\DELL\Desktop\SL-22061984\lib\main.dart:42'));
      expect(out, isNot(contains('C:\\Users')));
    });

    test('redacts a POSIX path including its first segment', () {
      // A leading \b in this pattern let the first segment through — the match
      // could not start at a space→'/' transition, so output read
      // "at /home[redacted]" and leaked the account or container name.
      final out = StartupDiagnostics.sanitizeVerbose(
          Exception('at /home/buildagent/app/lib/services/sync_service.dart:88'));
      expect(out, isNot(contains('buildagent')));
      expect(out, isNot(contains('/home')));
    });

    test('never throws, whatever the object does', () {
      // sanitizeVerbose runs inside error handlers and inside _record, so a
      // throw here used to mean the guarded step never completed at all.
      expect(StartupDiagnostics.sanitizeVerbose(_HostileError()), isA<String>());
      expect(StartupDiagnostics.sanitize(_HostileError()),
          StartupDiagnostics.genericFailure);
    });

    test('redacts long hex blobs — password hashes and salts', () {
      // 64 hex chars: exactly what sha256(salt + password) produces, and what an
      // exception carrying an app_users row would expose.
      const hash =
          'a3f1b2c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80';
      final out = StartupDiagnostics.sanitizeVerbose(Exception('hash=$hash'));
      expect(out, isNot(contains(hash)));
    });

    test('caps length so a huge payload cannot bloat local storage', () {
      final out = StartupDiagnostics.sanitizeVerbose(Exception('x' * 5000));
      expect(out.length, lessThan(450));
    });
  });

  group('reference IDs', () {
    final pattern =
        RegExp(r'^SL-\d{6}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$');

    test('are well formed', () {
      for (var i = 0; i < 50; i++) {
        expect(StartupDiagnostics.newReferenceId(), matches(pattern));
      }
    });

    test('avoid characters that are ambiguous when read aloud', () {
      // These get dictated down a noisy plant phone line.
      for (var i = 0; i < 200; i++) {
        final suffix = StartupDiagnostics.newReferenceId().split('-').last;
        expect(suffix, isNot(anyOf(contains('O'), contains('I'),
            contains('L'), contains('0'), contains('1'))));
      }
    });

    test('adopts a valid reference from the web boot script', () {
      StartupDiagnostics.adoptBootReference('SL-260926-K4F9');
      expect(StartupDiagnostics.sessionReference, 'SL-260926-K4F9');
    });

    test('tolerates a JSON-quoted value from the prefs encoding', () {
      // Reads through shared_preferences on web, where the plugin JSON-encodes.
      StartupDiagnostics.adoptBootReference('"SL-260926-K4F9"');
      expect(StartupDiagnostics.sessionReference, 'SL-260926-K4F9');
    });

    test('rejects malformed or hostile values rather than displaying them', () {
      // localStorage is attacker-writable, and this string ends up in
      // support-facing UI, so it must be validated and not merely trusted.
      for (final bad in <String?>[
        null,
        '',
        'not-a-reference',
        'SL-260926-OIL1', // ambiguous characters outside the alphabet
        '<script>alert(1)</script>',
        'SL-260926-K4F9 extra text',
      ]) {
        // Per ITERATION, not per test. `sessionReference` lazily generates and
        // caches an ID, and `adoptBootReference` returns early once one is set —
        // so without this reset only the first value in the list would actually
        // be exercised and the rest would pass vacuously.
        StartupDiagnostics.resetForTest();
        StartupDiagnostics.adoptBootReference(bad);
        expect(StartupDiagnostics.sessionReference, matches(pattern),
            reason: 'rejected input must leave a freshly generated ID: $bad');
      }
    });
  });

  group('report', () {
    test('contains no credentials, URLs or user identity', () {
      final json = StartupDiagnostics.report().toString();
      expect(json, isNot(contains('http')));
      expect(json, isNot(contains('eyJ')));
      expect(json, isNot(contains('AIza')));
    });
  });
}

/// An error whose `toString()` throws. Not hypothetical: any exception carrying a
/// custom object with a broken `toString` behaves this way, and it lands in the
/// sanitisers on the failure path where there is nothing left to catch it.
class _HostileError implements Exception {
  @override
  String toString() => throw StateError('toString itself throws');
}
