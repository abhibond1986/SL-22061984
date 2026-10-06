// lib/widgets/voice_text_field.dart
// Reusable text field with built-in voice input (speech-to-text).
// Supports dictation in user's selected language (EN/HI/BN/OR).
// Usage:
//   VoiceTextField(
//     controller: myCtrl,
//     label: 'Description',
//     hint: 'What happened?',
//     maxLines: 3,
//   )

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import '../main.dart' show AppColors, SL;
import '../services/i18n.dart';

class VoiceTextField extends StatefulWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final int maxLines;
  final bool obscure;
  final TextInputType? keyboardType;
  final void Function(String)? onChanged;

  const VoiceTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.maxLines = 1,
    this.obscure = false,
    this.keyboardType,
    this.onChanged,
  });

  @override
  State<VoiceTextField> createState() => _VoiceTextFieldState();
}

class _VoiceTextFieldState extends State<VoiceTextField> {
  static bool _micPermissionGranted = false;

  // ── One engine, many fields ───────────────────────────────────────────────
  // `stt.SpeechToText()` is a process-wide SINGLETON, and `initialize()` only
  // stores the status/error callbacks of the FIRST caller. Before 2026-10-06
  // every field kept its own "is listening" flag and the engine's callbacks
  // belonged to whichever field initialised first, so the second field on a
  // screen never heard its own "done", could start while the first session
  // was still shutting down (the browser then refuses to start and nothing is
  // written), and any field being disposed stopped whichever session was live.
  // Now one static owner holds the session and callbacks are routed to it.
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static _VoiceTextFieldState? _owner;
  static stt.SpeechStatusListener? _foreignStatus;
  static stt.SpeechErrorListener? _foreignError;
  static bool _speechAvailable = false;

  bool _isListening = false;
  int _session = 0;
  bool _sawListening = false;
  String _baseText = '';
  String _lastWords = '';
  Timer? _silence;

  /// Web ignores `pauseFor`, so a quiet mic would stay armed forever.
  static const _silenceLimit = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  static void _routeStatus(String status) {
    _owner?._onStatus(status);
    _foreignStatus?.call(status);
  }

  static void _routeError(SpeechRecognitionError e) {
    _owner?._onError(e);
    _foreignError?.call(e);
  }

  /// Puts the router in front of whatever callbacks the singleton holds
  /// (e.g. the Near Miss tab's), keeping those working as well.
  static void _installRouter() {
    if (_speech.statusListener != _routeStatus) {
      _foreignStatus = _speech.statusListener;
      _speech.statusListener = _routeStatus;
    }
    if (_speech.errorListener != _routeError) {
      _foreignError = _speech.errorListener;
      _speech.errorListener = _routeError;
    }
  }

  Future<void> _initSpeech() async {
    try {
      if (!kIsWeb && !_micPermissionGranted) {
        final status = await Permission.microphone.request();
        if (status != PermissionStatus.granted) return;
        _micPermissionGranted = true;
      }
      if (!_speechAvailable) {
        _speechAvailable = await _speech.initialize(
            onError: _routeError, onStatus: _routeStatus);
      }
      _installRouter();
    } catch (e) {
      debugPrint('VoiceTextField: speech init failed: $e');
      _speechAvailable = false;
    }
    if (mounted) setState(() {});
  }

  void _onStatus(String status) {
    if (status == 'listening') {
      _sawListening = true;
      return;
    }
    // A late "done" from the PREVIOUS session can arrive just after this one
    // started; only end once this session has actually been listening.
    if ((status == 'done' || status == 'notListening' ||
            status == 'doneNoResult') &&
        _sawListening) {
      _finish();
    }
  }

  void _onError(SpeechRecognitionError e) {
    debugPrint('VoiceTextField: speech error ${e.errorMsg}');
    _finish();
  }

  void _finish() {
    _silence?.cancel();
    if (_owner == this) _owner = null;
    if (mounted && _isListening) setState(() => _isListening = false);
  }

  void _armSilence(int session) {
    _silence?.cancel();
    _silence = Timer(_silenceLimit, () {
      if (_owner == this && _session == session && _isListening) {
        _speech.stop();
        _finish();
      }
    });
  }

  /// Get the locale ID for speech recognition based on app language
  String _getSpeechLocale() {
    switch (I18n.currentLang) {
      case 'hi': return 'hi_IN';
      default:   return 'en_IN';  // en_IN for Indian English
    }
  }

  /// Collapses phrases the recogniser repeats back-to-back. Chrome (notably
  /// on Android) can return every interim step as its own result — "near",
  /// "near cast", "near cast house" — and the plugin joins them all, giving
  /// "near near cast near cast house". Removing an immediately repeated run of
  /// words (keeping the later, longer copy) restores "near cast house".
  @visibleForTesting
  static String collapseRepeats(String text) {
    final w = text.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
    var changed = true;
    while (changed) {
      changed = false;
      outer:
      for (var len = w.length ~/ 2; len >= 1; len--) {
        for (var i = 0; i + 2 * len <= w.length; i++) {
          var same = true;
          for (var k = 0; k < len; k++) {
            if (w[i + k].toLowerCase() != w[i + len + k].toLowerCase()) {
              same = false;
              break;
            }
          }
          if (same) {
            w.removeRange(i, i + len);
            changed = true;
            break outer;
          }
        }
      }
    }
    return w.join(' ');
  }

  void _write(String words) {
    final spoken = collapseRepeats(words);
    final text = spoken.isEmpty
        ? _baseText
        : (_baseText.trim().isEmpty ? spoken : '${_baseText.trimRight()} $spoken');
    if (widget.controller.text == text) return;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onChanged?.call(text);
  }

  Future<void> _stopOwner() async {
    final prev = _owner;
    if (prev == null && !_speech.isListening) return;
    try { await _speech.stop(); } catch (_) {}
    prev?._finish();
    // The browser fires "end" asynchronously; starting before it has done so
    // throws InvalidStateError and the new field silently gets nothing.
    for (var i = 0; i < 10 && _speech.isListening; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await Future.delayed(const Duration(milliseconds: 250));
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      try { await _speech.stop(); } catch (_) {}
      _finish();
      return;
    }

    if (!_speechAvailable) {
      await _initSpeech();
      if (!_speechAvailable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(I18n.t('msg.permissionDenied')),
            backgroundColor: AppColors.red));
        }
        return;
      }
    }

    await _stopOwner();
    if (!mounted) return;
    _installRouter();
    _owner = this;
    final session = ++_session;
    _sawListening = false;
    _baseText = widget.controller.text;
    _lastWords = '';
    setState(() => _isListening = true);

    Future<void> start() => _speech.listen(
          onResult: (result) {
            if (_owner != this || _session != session || !mounted) return;
            _sawListening = true;
            final words = result.recognizedWords;
            if (words != _lastWords) {
              _lastWords = words;
              _armSilence(session);
            }
            _write(words);
          },
          localeId: _getSpeechLocale(),
          listenMode: stt.ListenMode.dictation,
          listenFor: const Duration(minutes: 3),
          pauseFor: const Duration(seconds: 10),
          cancelOnError: true,
          partialResults: true,
        );

    try {
      await start();
    } catch (e) {
      // Usually "recognition has already started": give the engine a moment
      // to finish the previous session, then try once more.
      debugPrint('VoiceTextField: listen failed ($e), retrying');
      try { await _speech.cancel(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 600));
      if (_owner != this || _session != session || !mounted) return;
      try {
        await start();
      } catch (e2) {
        debugPrint('VoiceTextField: listen failed again: $e2');
        _finish();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Microphone is busy. Tap the mic again.')));
        }
        return;
      }
    }
    if (_owner == this && _session == session) _armSilence(session);
  }

  @override
  void dispose() {
    _silence?.cancel();
    // Only stop the engine if THIS field owns the session; another field on
    // the screen may be mid-dictation.
    if (_owner == this) {
      _owner = null;
      _speech.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!.toUpperCase(),
            style: TextStyle(
              color: sl.text4, fontSize: 9,
              fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          const SizedBox(height: 6),
        ],
        TextField(
          controller: widget.controller,
          obscureText: widget.obscure,
          maxLines: widget.maxLines,
          keyboardType: widget.keyboardType,
          onChanged: widget.onChanged,
          style: TextStyle(color: sl.text1, fontSize: 13),
          decoration: InputDecoration(
            hintText: widget.hint ?? I18n.t('nearMiss.tapToTalk'),
            hintStyle: TextStyle(color: sl.text4, fontSize: 11),
            filled: true,
            fillColor: sl.card2,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: sl.border)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: sl.border)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: AppColors.accent, width: 1.5)),
            suffixIcon: widget.obscure ? null : GestureDetector(
              onTap: _toggleListening,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.all(6),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _isListening
                    ? AppColors.red.withOpacity(0.15)
                    : AppColors.accent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isListening
                      ? AppColors.red.withOpacity(0.5)
                      : AppColors.accent.withOpacity(0.3))),
                child: Icon(
                  _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                  color: _isListening ? sl.redText : sl.accentText,
                  size: 18),
              ),
            ),
          ),
        ),
        if (_isListening)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(
                  color: AppColors.red, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(I18n.t('nearMiss.recording'),
                style: TextStyle(color: sl.redText, fontSize: 10,
                  fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text('(${I18n.langName(I18n.currentLang)})',
                style: TextStyle(color: sl.text4, fontSize: 9)),
            ]),
          ),
      ],
    );
  }
}

/// Test access to the private dictation helpers (tools/voice_field_test.dart).
@visibleForTesting
class VoiceTextFieldTestHooks {
  static String collapse(String text) =>
      _VoiceTextFieldState.collapseRepeats(text);
}
