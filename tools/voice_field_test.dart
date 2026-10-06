// Voice dictation in VoiceTextField (AI Scan "Location" + "What is in the
// picture?", SOP fields).
//
// Reproduces the owner's 2026-10-06 report: dictated words were written
// several times ("near near cast near cast house ..."), and the SECOND voice
// field on the screen never received any words.
//
// Run: copy to test/ and `flutter test test/voice_field_test.dart`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/widgets/voice_text_field.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';

/// Behaves like the browser engine: one recogniser, refuses to start while a
/// session is still running, and reports "end" a little after stop().
class FakeEngine extends SpeechToTextPlatform {
  bool active = false;
  int listenCalls = 0;
  int refusedStarts = 0;

  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<bool> initialize({debugLogging = false, List<SpeechConfigOption>? options}) async => true;
  @override
  Future<List<dynamic>> locales() async => ['en_IN:English'];

  @override
  Future<bool> listen({
    String? localeId,
    partialResults = true,
    onDevice = false,
    int listenMode = 0,
    sampleRate = 0,
    SpeechListenOptions? options,
  }) async {
    listenCalls++;
    if (active) {
      refusedStarts++;
      throw PlatformException(code: 'InvalidStateError',
          message: 'recognition has already started');
    }
    active = true;
    onStatus?.call('listening');
    return true;
  }

  @override
  Future<void> stop() async {
    // The browser's "end" event arrives asynchronously.
    Future.delayed(const Duration(milliseconds: 150), () {
      active = false;
      onStatus?.call('notListening');
      onStatus?.call('done');
    });
  }

  @override
  Future<void> cancel() => stop();

  void say(String words, {bool last = false}) {
    onTextRecognition?.call(jsonEncode(SpeechRecognitionResult(
        [SpeechRecognitionWords(words, 0.9)], last).toJson()));
  }
}

void main() {
  test('collapseRepeats removes back-to-back repeated phrases', () {
    final c = VoiceTextFieldTestHooks.collapse;
    expect(c('near near cast near cast house'), 'near cast house');
    expect(c('near cast house near cast house near cast house'),
        'near cast house');
    expect(c('rooftop sheet replacement at 12 m'),
        'rooftop sheet replacement at 12 m');
    expect(c('BF-2 cast house bay 4'), 'BF-2 cast house bay 4');
  });

  testWidgets('two voice fields: no repeats, second field gets its words',
      (t) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async => call.method == 'requestPermissions'
            ? {7: 1} // microphone: granted
            : 1);
    final engine = FakeEngine();
    SpeechToTextPlatform.instance = engine;

    final loc = TextEditingController();
    final ctx = TextEditingController();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          VoiceTextField(controller: loc, label: 'Location'),
          VoiceTextField(controller: ctx, label: 'What is in the picture?',
              maxLines: 3),
        ]),
      ),
    ));
    await t.pump(const Duration(milliseconds: 50));

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    // ── Field 1: interim results grow, as the recogniser sends them.
    await t.tap(find.byIcon(Icons.mic_rounded).first);
    await settle();
    engine.say('near');
    engine.say('near cast');
    engine.say('near cast house');
    // Chrome-on-Android style aggregated duplicates.
    engine.say('near near cast near cast house');
    await t.pump();
    expect(loc.text, 'near cast house');

    // ── Field 2 tapped while field 1 is STILL listening.
    await t.tap(find.byIcon(Icons.mic_rounded).first); // field 1 now shows stop
    await settle();
    expect(engine.refusedStarts, 0,
        reason: 'must wait for the previous session to end before starting');
    engine.say('rooftop sheet');
    engine.say('rooftop sheet replacement', last: true);
    await t.pump();
    expect(ctx.text, 'rooftop sheet replacement');
    expect(loc.text, 'near cast house', reason: 'field 1 must be untouched');

    // Field 2 ends normally and its own indicator clears.
    await t.tap(find.byIcon(Icons.stop_rounded));
    await settle();
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsNWidgets(2));

    // A second dictation into field 1 appends after the existing text once.
    await t.tap(find.byIcon(Icons.mic_rounded).first);
    await settle();
    engine.say('bay');
    engine.say('bay 4');
    await t.pump();
    expect(loc.text, 'near cast house bay 4');
    await t.tap(find.byIcon(Icons.stop_rounded));
    await settle();
    await t.pumpWidget(const SizedBox());
    await settle();
  });
}
