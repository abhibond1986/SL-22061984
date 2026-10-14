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
import '../main.dart' show AppColors, SL;
import '../services/dictation_session.dart' as dictation;
import '../services/i18n.dart';
import '../services/voice_engine.dart';

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
  // ── One engine, many fields ───────────────────────────────────────────────
  // `stt.SpeechToText()` is a process-wide SINGLETON whose `initialize()` keeps
  // only the FIRST caller's callbacks. This widget used to hold its own static
  // owner + router; since 2026-10-14 that lives in VoiceEngine so the Near Miss
  // screen shares it too (AUDIT_2026-10-14_NEAR_MISS_MIC.md). Exactly one
  // field — here or on Near Miss — owns the engine at a time; a new claim tells
  // the previous owner it lost the session.
  bool _speechAvailable = false;

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

  Future<void> _initSpeech() async {
    _speechAvailable = await VoiceEngine.ensureReady();
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

  void _onError(String code) {
    debugPrint('VoiceTextField: speech error $code');
    _finish();
  }

  void _finish() {
    _silence?.cancel();
    VoiceEngine.release(this);
    if (mounted && _isListening) setState(() => _isListening = false);
  }

  void _armSilence(int session) {
    _silence?.cancel();
    _silence = Timer(_silenceLimit, () {
      if (VoiceEngine.owns(this) && _session == session && _isListening) {
        VoiceEngine.stop();
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

  /// Collapses phrases the recogniser repeats back-to-back (Chrome on Android
  /// returns every interim step as its own result). Shared with Near Miss.
  @visibleForTesting
  static String collapseRepeats(String text) => dictation.collapseRepeats(text);

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

  Future<void> _toggleListening() async {
    if (_isListening) {
      await VoiceEngine.stop();
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

    // Ends whichever session is live — in this widget or on Near Miss — and
    // waits for the browser's `end` before starting, or it refuses to start.
    await VoiceEngine.stopAndWait();
    if (!mounted) return;
    VoiceEngine.claim(this,
        onStatus: _onStatus, onError: _onError, onLost: _finish);
    final session = ++_session;
    _sawListening = false;
    _baseText = widget.controller.text;
    _lastWords = '';
    setState(() => _isListening = true);

    Future<void> start() => VoiceEngine.listen(
          onWords: (words) {
            if (!VoiceEngine.owns(this) || _session != session || !mounted) {
              return;
            }
            _sawListening = true;
            if (words != _lastWords) {
              _lastWords = words;
              _armSilence(session);
            }
            _write(words);
          },
          localeId: _getSpeechLocale(),
          pauseFor: const Duration(seconds: 10),
          cancelOnError: true,
        );

    try {
      await start();
    } catch (e) {
      // Usually "recognition has already started": give the engine a moment
      // to finish the previous session, then try once more.
      debugPrint('VoiceTextField: listen failed ($e), retrying');
      await VoiceEngine.cancel();
      await Future.delayed(const Duration(milliseconds: 600));
      if (!VoiceEngine.owns(this) || _session != session || !mounted) return;
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
    if (VoiceEngine.owns(this) && _session == session) _armSilence(session);
  }

  @override
  void dispose() {
    _silence?.cancel();
    // Only stop the engine if THIS field owns the session; another field on
    // the screen may be mid-dictation.
    if (VoiceEngine.owns(this)) {
      VoiceEngine.release(this);
      VoiceEngine.stop();
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
