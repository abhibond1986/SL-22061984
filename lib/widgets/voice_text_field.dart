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

import 'package:flutter/material.dart';
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
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    if (!_micPermissionGranted) {
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) return;
      _micPermissionGranted = true;
    }

    _speechAvailable = await _speech.initialize(
      onError: (e) {
        if (mounted) setState(() => _isListening = false);
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _isListening = false);
        }
      },
    );
    if (mounted) setState(() {});
  }

  /// Get the locale ID for speech recognition based on app language
  String _getSpeechLocale() {
    switch (I18n.currentLang) {
      case 'hi': return 'hi_IN';
      default:   return 'en_IN';  // en_IN for Indian English
    }
  }

  Future<void> _toggleListening() async {
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

    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      setState(() => _isListening = true);
      await _speech.listen(
        onResult: (result) {
          if (result.recognizedWords.isNotEmpty) {
            final current = widget.controller.text;
            final newText = current.isEmpty
                ? result.recognizedWords
                : '$current ${result.recognizedWords}';
            widget.controller.text = newText;
            widget.controller.selection = TextSelection.fromPosition(
              TextPosition(offset: newText.length));
            if (widget.onChanged != null) widget.onChanged!(newText);
          }
        },
        localeId: _getSpeechLocale(),
        listenMode: stt.ListenMode.dictation,
        listenFor: const Duration(minutes: 3),
        pauseFor: const Duration(seconds: 10),
        cancelOnError: true,
        partialResults: true,
      );
    }
  }

  @override
  void dispose() {
    _speech.stop();
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
