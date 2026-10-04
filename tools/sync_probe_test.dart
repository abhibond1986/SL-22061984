// Live probe: runs the app's real SyncService.fullSync against the configured
// Supabase project from a clean device and times every stage.
// Run from a project copy:  flutter test test/sync_probe_test.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:safety_lens/services/local_db.dart';
import 'package:safety_lens/services/supabase_service.dart';
import 'package:safety_lens/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test stubs all HTTP to 400; this probe needs the real network.
  HttpOverrides.global = null;

  test('fullSync against live server', () async {
    SharedPreferences.setMockInitialValues({});
    await LocalDB.init();
    await SupabaseService.init();
    await SyncService.init();

    Future<T> time<T>(String label, Future<T> Function() f) async {
      final sw = Stopwatch()..start();
      try {
        final r = await f();
        // ignore: avoid_print
        print('[probe] $label: ${sw.elapsedMilliseconds} ms');
        return r;
      } catch (e) {
        // ignore: avoid_print
        print('[probe] $label THREW after ${sw.elapsedMilliseconds} ms: $e');
        rethrow;
      }
    }

    final inc = await time('fetchIncidentsOrNull',
        () => SupabaseService.fetchIncidentsOrNull());
    // ignore: avoid_print
    print('[probe]   incidents: ${inc?.length}');
    final kb = await time('fetchKnowledgeDocs',
        () => SupabaseService.fetchKnowledgeDocs());
    // ignore: avoid_print
    print('[probe]   kb rows: ${kb.length}');
    final res = await time('fullSync(force)', () => SyncService.fullSync(force: true));
    // ignore: avoid_print
    print('[probe] result: ${res..remove('stillUnsyncedIds')}');
    expect(res['ok'], true);
    expect(SyncService.serverReachedWithin(const Duration(minutes: 1)), true);
    expect(SyncService.lastSyncError, '');
  }, timeout: const Timeout(Duration(minutes: 4)));

  // The phone failure: one run that never finishes (a request frozen by iOS
  // Safari while the tab was in the background) used to hold the sync lock
  // forever, so every later sync — and the Retry button — hung behind it.
  test('a hung sync run no longer blocks the next one', () async {
    SyncService.runWatchdog = const Duration(seconds: 2);
    final hung = SyncService.debugRunExclusive(() => Completer<int>().future);
    // Attach the expectation now, so the timeout error is not "unhandled".
    final hungExpect = expectLater(hung, throwsA(isA<TimeoutException>()));
    final sw = Stopwatch()..start();
    final next = await SyncService.debugRunExclusive(() async => 42)
        .timeout(const Duration(seconds: 10));
    expect(next, 42);
    await hungExpect;
    // ignore: avoid_print
    print('[probe] queued run completed after ${sw.elapsedMilliseconds} ms');
    SyncService.runWatchdog = const Duration(seconds: 75);
  });
}
