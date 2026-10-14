// lib/services/voice_engine.dart
//
// The ONE owner of the app-wide speech engine.
//
// `stt.SpeechToText()` is a process-wide singleton, and its `initialize()`
// stores the status/error callbacks of the FIRST caller only — every later
// call returns `true` and silently drops the new callbacks (plugin source:
// `if (_initWorked) return Future.value(_initWorked);`).
//
// The Near Miss screen is rebuilt on every section switch, so from the second
// visit on the engine was reporting to a State that no longer existed: the mic
// stayed red after the engine had stopped, words were lost, and no error ever
// reached the screen. If AI Scan's voice fields had been used first, Near Miss
// never received a callback at all. (AUDIT_2026-10-14_NEAR_MISS_MIC.md, #1.)
//
// Here the engine is initialised once with a ROUTER, and whoever is dictating
// right now claims the router. A claim by a new owner tells the previous one it
// lost the engine, so two screens can never both believe they are listening.
// VoiceTextField (AI Scan, SOP) and the Near Miss screen both go through this.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class VoiceEngine {
  VoiceEngine._();

  static final stt.SpeechToText speech = stt.SpeechToText();

  static bool _available = false;
  static bool _micPermissionGranted = false;

  static Object? _owner;
  static void Function(String status)? _onStatus;
  /// Receives the error CODE ("not-allowed", "error_no_match", …).
  static void Function(String code)? _onError;
  static void Function()? _onLost;

  /// True from `listen()` until the engine reports it has ended. The plugin's
  /// own `isListening` drops to false the instant `stop()` is CALLED, long
  /// before the browser has actually finished, so it cannot be used to decide
  /// when a new session may start.
  static bool _busy = false;

  /// Chrome on Android returns every interim step as its own result.
  /// Flutter web derives defaultTargetPlatform from the user agent.
  static bool get isAndroidWeb =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get available => _available;

  /// Permission (native) + one-time initialise + router installation.
  /// Safe to call repeatedly; returns whether voice input can be used.
  static Future<bool> ensureReady() async {
    try {
      if (!kIsWeb && !_micPermissionGranted) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          debugPrint('VoiceEngine: microphone permission denied ($status)');
          return false;
        }
        _micPermissionGranted = true;
      }
      if (!_available) {
        _available = await speech.initialize(
          onStatus: _routeStatus,
          onError: _routeError,
          options: isAndroidWeb ? [stt.SpeechToText.webDoNotAggregate] : null,
        );
      }
      // Whoever initialised first, the router must be what the engine calls.
      speech.statusListener = _routeStatus;
      speech.errorListener = _routeError;
    } catch (e) {
      debugPrint('VoiceEngine: init failed: $e');
      _available = false;
    }
    return _available;
  }

  static void _routeStatus(String status) {
    if (status == 'listening') {
      _busy = true;
    } else if (status == 'done' ||
        status == 'notListening' ||
        status == 'doneNoResult') {
      _busy = false;
    }
    _onStatus?.call(status);
  }

  static void _routeError(SpeechRecognitionError error) {
    debugPrint('VoiceEngine: error ${error.errorMsg} '
        '(permanent: ${error.permanent})');
    _onError?.call(error.errorMsg);
  }

  /// Make [owner] the receiver of engine events. A different current owner is
  /// told (via its onLost) that it no longer has the engine.
  static void claim(
    Object owner, {
    required void Function(String status) onStatus,
    required void Function(String code) onError,
    void Function()? onLost,
  }) {
    if (_owner != null && !identical(_owner, owner)) {
      final lost = _onLost;
      _clear();
      lost?.call();
    }
    _owner = owner;
    _onStatus = onStatus;
    _onError = onError;
    _onLost = onLost;
  }

  /// Drop [owner]'s claim. No-op if someone else owns the engine now.
  static void release(Object owner) {
    if (identical(_owner, owner)) _clear();
  }

  static bool owns(Object owner) => identical(_owner, owner);

  static void _clear() {
    _owner = null;
    _onStatus = null;
    _onError = null;
    _onLost = null;
  }

  /// End whatever session is live (telling its owner), and wait until the
  /// engine can accept a new one.
  static Future<void> stopAndWait() async {
    final lost = _onLost;
    final hadOwner = _owner != null;
    _clear();
    lost?.call();
    if (hadOwner || _busy || speech.isListening) {
      try {
        await speech.stop();
      } catch (_) {}
    }
    await waitIdle();
  }

  /// Wait (up to ~1.5 s) for the engine to report that its last session has
  /// ended, plus a short margin: browsers throw "recognition has already
  /// started" if a new session is started before their `end` event.
  static Future<void> waitIdle() async {
    for (var i = 0; i < 15 && _busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  /// Start one recognition segment. [pauseFor] is left null for Near Miss on
  /// purpose: its own DictationSession is the authority on silence, and a
  /// plugin-side pause stop would just look like another engine dropout.
  static Future<void> listen({
    required String localeId,
    required void Function(String words) onWords,
    Duration? pauseFor,
    bool cancelOnError = false,
  }) {
    _busy = true;
    return speech.listen(
      onResult: (r) => onWords(r.recognizedWords),
      localeId: localeId,
      listenFor: const Duration(minutes: 3),
      pauseFor: pauseFor,
      partialResults: true,
      cancelOnError: cancelOnError,
      listenMode: stt.ListenMode.dictation,
    );
  }

  /// Stop the engine without waiting.
  static Future<void> stop() async {
    try {
      await speech.stop();
    } catch (_) {}
  }

  /// Abort the engine (no final result).
  static Future<void> cancel() async {
    try {
      await speech.cancel();
    } catch (_) {}
  }
}
