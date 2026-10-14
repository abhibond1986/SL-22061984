// Near Miss dictation state machine — AUDIT_2026-10-14_NEAR_MISS_MIC.md.
//
// Plain Dart, no Flutter: `dart run tools/dictation_session_test.dart`.
// The fake engine reproduces each device behaviour the audit found:
// phones ending at the first pause, the permission prompt delaying
// 'listening', a late 'done' from an older session, browser errors, and
// Chrome-Android's duplicated words.
//
// Timings are scaled down (silence 300 ms, startup 600 ms) so the suite runs
// in a few seconds; the logic is identical at 5 s / 12 s.

import 'dart:async';
import 'dart:io';

import '../lib/services/dictation_session.dart';

int _pass = 0, _fail = 0;
void check(bool ok, String what) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    stdout.writeln('  FAIL: $what');
  }
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

class FakeEngine {
  int listens = 0;
  int stops = 0;
  int throwNextListens = 0;
  bool autoListening = true; // emit 'listening' right after listen()
  void Function(String)? words;
  late DictationSession s;

  Future<void> listen(void Function(String) onWords) async {
    listens++;
    if (throwNextListens > 0) {
      throwNextListens--;
      throw StateError('recognition has already started');
    }
    words = onWords;
    if (autoListening) {
      scheduleMicrotask(() => s.handleStatus('listening'));
    }
  }

  Future<void> stop() async => stops++;
  Future<void> idle() async {}

  /// Engine ends the segment by itself — what phones do at a 1-3 s pause.
  void dropout() {
    s.handleStatus('notListening');
    s.handleStatus('done');
  }
}

class Run {
  final FakeEngine e = FakeEngine();
  late final DictationSession s;
  final List<String> texts = [];
  DictationEnd? reason;
  bool? heard;
  int ended = 0;
  int live = 0;

  Run({String base = '', bool collapse = false}) {
    s = DictationSession(
      listen: e.listen,
      stop: e.stop,
      waitIdle: e.idle,
      baseText: base,
      collapse: collapse,
      onText: texts.add,
      onLive: () => live++,
      onEnded: (r, h) {
        ended++;
        reason = r;
        heard = h;
      },
      silenceLimit: const Duration(milliseconds: 300),
      startupLimit: const Duration(milliseconds: 600),
      maxDuration: const Duration(seconds: 20),
      restartDelay: const Duration(milliseconds: 20),
    );
    e.s = s;
  }
}

Future<void> main() async {
  // 1 ─ Phone ends at the first pause; the worker keeps talking.
  {
    final r = Run();
    await r.s.start();
    await wait(10);
    r.e.words!('there was oil');
    r.e.words!('there was oil on the floor');
    await wait(50);
    r.e.dropout(); // Android / Chrome-Android / iPhone: pause ⇒ engine ends
    await wait(80);
    check(r.s.isActive, '1: session survives an engine-chosen end');
    check(r.e.listens == 2, '1: engine restarted (listens=${r.e.listens})');
    r.e.words!('near conveyor 3');
    await wait(10);
    check(r.s.text == 'there was oil on the floor near conveyor 3',
        '1: second segment appended once, got "${r.s.text}"');
    await wait(400);
    check(r.reason == DictationEnd.silence && r.heard == true,
        '1: ends on silence with heard=true (${r.reason})');
    check(r.ended == 1, '1: onEnded exactly once (${r.ended})');
  }

  // 2 ─ Permission prompt: 'listening' arrives late. The 5 s clock must not
  //     run during the prompt.
  {
    final r = Run();
    r.e.autoListening = false;
    await r.s.start();
    await wait(450); // > silenceLimit, < startupLimit
    check(r.s.isActive, '2: not killed by silence while the prompt is open');
    check(r.live == 0, '2: not live yet');
    r.s.handleStatus('listening'); // user tapped Allow
    check(r.live == 1, '2: live once listening arrives');
    await wait(150);
    r.e.words!('gas smell near bay 2');
    await wait(150);
    check(r.s.isActive, '2: silence clock counts from the words');
    await wait(250);
    check(r.reason == DictationEnd.silence && r.s.text == 'gas smell near bay 2',
        '2: normal end afterwards (${r.reason}, "${r.s.text}")');
  }

  // 3 ─ Mic never comes up at all.
  {
    final r = Run();
    r.e.autoListening = false;
    await r.s.start();
    await wait(700);
    check(r.reason == DictationEnd.micNeverStarted,
        '3: micNeverStarted (${r.reason})');
    check(r.e.stops == 1, '3: engine stopped');
  }

  // 4 ─ A late 'done' from the PREVIOUS session must not kill this one.
  {
    final r = Run();
    r.e.autoListening = false;
    await r.s.start();
    r.s.handleStatus('notListening'); // belongs to the old session
    r.s.handleStatus('done');
    await wait(60);
    check(r.s.isActive && r.e.listens == 1,
        '4: late end before listening is ignored (listens=${r.e.listens})');
    await r.s.userStop();
  }

  // 5 ─ Fatal browser errors end the session with a reason.
  for (final code in [
    'not-allowed',
    'service-not-allowed',
    'audio-capture',
    'network',
    'language-not-supported',
    'error_permission',
  ]) {
    final r = Run(base: 'Oil leak');
    await r.s.start();
    await wait(10);
    r.s.handleError(code);
    check(r.reason == DictationEnd.failed && r.s.lastErrorCode == code,
        '5: $code ⇒ failed (${r.reason})');
    check(r.heard == false, '5: $code heard=false');
    final msg = voiceProblemMessage(code, web: true, langName: 'English');
    check(!msg.startsWith('Voice input stopped'),
        '5: $code has a specific message');
  }

  // 6 ─ "no-speech" during silence is NOT an error: restart, then silence end.
  {
    final r = Run();
    await r.s.start();
    await wait(10);
    r.s.handleError('no-speech');
    r.s.handleStatus('done'); // web sends doneNoResult/done after an error
    await wait(60);
    check(r.s.isActive && r.e.listens == 2,
        '6: one restart after no-speech (listens=${r.e.listens})');
    await wait(350);
    check(r.reason == DictationEnd.silence && r.heard == false,
        '6: silence end, nothing heard (${r.reason})');
  }

  // 7 ─ "recognition has already started": retried, then a clear failure.
  {
    final r = Run();
    r.e.throwNextListens = 1;
    await r.s.start();
    await wait(80);
    check(r.s.isActive && r.e.listens == 2,
        '7: one refused start is retried (listens=${r.e.listens})');
    await r.s.userStop();

    final r2 = Run();
    r2.e.throwNextListens = 99;
    await r2.s.start();
    await wait(400);
    check(r2.reason == DictationEnd.failed,
        '7: persistent refusal ⇒ failed, not a silent hang (${r2.reason})');
  }

  // 8 ─ Chrome-Android duplicates, with collapse on.
  {
    final r = Run(collapse: true);
    await r.s.start();
    await wait(10);
    r.e.words!('near near cast near cast house');
    check(r.s.text == 'near cast house', '8: collapsed, got "${r.s.text}"');
    await r.s.userStop();
  }

  // 9 ─ Base text, repeated partials, user stop, late words after stop.
  {
    final r = Run(base: 'Crane hook');
    await r.s.start();
    await wait(10);
    final w = r.e.words!;
    w('latch');
    w('latch broken');
    w('latch broken'); // repeated partial: no new write
    check(r.texts.length == 2, '9: repeated partial ignored (${r.texts})');
    check(r.s.text == 'Crane hook latch broken', '9: "${r.s.text}"');
    await r.s.userStop();
    w('latch broken at bay'); // late final result after stop
    check(r.s.text == 'Crane hook latch broken', '9: late words ignored');
    check(r.reason == DictationEnd.userStopped && r.heard == true,
        '9: userStopped heard=true');
    check(r.e.stops == 1, '9: engine stopped once');
  }

  // 10 ─ Superseded by another field: no engine stop (it isn't ours now).
  {
    final r = Run();
    await r.s.start();
    await r.s.end(DictationEnd.superseded, stopEngine: false);
    check(r.reason == DictationEnd.superseded && r.e.stops == 0,
        '10: superseded without stopping the new owner');
    r.s.handleStatus('done');
    r.s.handleError('network');
    check(r.ended == 1, '10: events after end ignored');
  }

  // 11 ─ Error classification + messages.
  check(classifyVoiceError('NO-SPEECH') == VoiceErrorKind.transient, '11a');
  check(classifyVoiceError('error_busy') == VoiceErrorKind.busy, '11b');
  check(classifyVoiceError('weird') == VoiceErrorKind.unknown, '11c');
  check(voiceProblemMessage('weird', web: true, langName: 'English')
      .contains('(weird)'), '11d: unknown code shown');
  check(collapseRepeats('rooftop sheet replacement at 12 m') ==
      'rooftop sheet replacement at 12 m', '11e: no false collapse');

  stdout.writeln('dictation_session_test: $_pass passed, $_fail failed');
  exit(_fail == 0 ? 0 : 1);
}
