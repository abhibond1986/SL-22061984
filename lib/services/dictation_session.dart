// lib/services/dictation_session.dart
//
// ONE dictation into ONE text field, as a plain-Dart state machine.
//
// Why this exists (AUDIT_2026-10-14_NEAR_MISS_MIC.md): the Near Miss mic
// "sometimes picks up the voice, sometimes doesn't, and varies across devices".
// Every cause was a timing rule living inside a widget State, where none of it
// could be tested:
//
//  * Phones (Android app, Chrome-Android, iPhone) end a recognition session on
//    their own at the first 1-3 s pause. The old code took that as "finished",
//    so a worker pausing mid-sentence was cut off. Here an engine-chosen end is
//    a DROPOUT: the session restarts listening and keeps the text so far. Only
//    the user, 5 s of real silence, a fatal error or the time cap end it.
//  * The 5 s clock was started when `listen()` returned — but on web that is
//    immediately, before the "Allow microphone?" prompt is even answered. The
//    clock now starts on the engine's `listening` status (or the first words),
//    with a separate, longer startup limit if the mic never comes up.
//  * A late "done" from an earlier session killed the new one. A segment now
//    ignores end events until it has itself been heard to be listening.
//  * Errors were swallowed. Each one is classified here; fatal ones end the
//    session with a reason the UI turns into a sentence the worker can act on.
//
// Imports nothing from Flutter, so `dart run tools/dictation_session_test.dart`
// exercises all of it on the plain VM.

import 'dart:async';

/// Why a session ended. The UI decides what to say and whether to hand the
/// text to the AI from this alone.
enum DictationEnd {
  /// The worker tapped the mic / STOP.
  userStopped,

  /// [DictationSession.silenceLimit] passed with no new words.
  silence,

  /// The engine never reported `listening` within the startup limit — most
  /// often an unanswered or dismissed microphone-permission prompt.
  micNeverStarted,

  /// A fatal engine error; see [DictationSession.lastErrorCode].
  failed,

  /// [DictationSession.maxDuration] reached.
  timeLimit,

  /// The worker started dictating into a different field.
  switchedField,

  /// Another voice field elsewhere in the app took the engine.
  superseded,

  /// The screen went away.
  disposed,
}

/// What an engine error means for the session.
enum VoiceErrorKind {
  /// Normal during silence ("no-speech", Android "error_no_match"). Restart.
  transient,

  /// Engine momentarily unavailable ("error_busy", "error_client"). Restart,
  /// but give up after a few in a row.
  busy,

  /// Microphone permission refused for this site / app.
  blocked,

  /// Speech service switched off or absent (iPhone Dictation off, browser
  /// without support).
  disabled,

  /// No microphone, or another app holds it.
  noMic,

  /// The speech service could not be reached (Chrome and Edge recognise on a
  /// server; office networks and weak mobile data break this).
  network,

  /// The chosen language has no recogniser on this device / browser.
  language,

  /// Anything else. Treated like [busy].
  unknown,
}

/// Classify an error code from either the web plugin (W3C names such as
/// "not-allowed") or the Android / iOS plugin ("error_permission").
VoiceErrorKind classifyVoiceError(String code) {
  switch (code.trim().toLowerCase()) {
    case 'no-speech':
    case 'error_no_match':
    case 'error_speech_timeout':
    case 'aborted':
      return VoiceErrorKind.transient;
    case 'error_busy':
    case 'error_recognizer_busy':
    case 'error_client':
    case 'error_server_disconnected':
    case 'error_retry':
      return VoiceErrorKind.busy;
    case 'not-allowed':
    case 'error_permission':
      return VoiceErrorKind.blocked;
    case 'service-not-allowed':
    case 'error_speech_recognizer_disabled':
    case 'not supported':
    case 'speech_not_supported':
      return VoiceErrorKind.disabled;
    case 'audio-capture':
    case 'error_audio_error':
      return VoiceErrorKind.noMic;
    case 'network':
    case 'error_network':
    case 'error_network_timeout':
    case 'error_server':
    case 'error_too_many_requests':
      return VoiceErrorKind.network;
    case 'language-not-supported':
    case 'error_language_not_supported':
    case 'error_language_unavailable':
      return VoiceErrorKind.language;
  }
  return VoiceErrorKind.unknown;
}

bool _isFatal(VoiceErrorKind k) =>
    k != VoiceErrorKind.transient &&
    k != VoiceErrorKind.busy &&
    k != VoiceErrorKind.unknown;

/// One sentence the worker can act on, for a session that ended [failed].
String voiceProblemMessage(String? code,
    {required bool web, required String langName}) {
  final kind = classifyVoiceError(code ?? '');
  switch (kind) {
    case VoiceErrorKind.blocked:
      return web
          ? 'Microphone is blocked for this site. Tap the lock icon next to '
              'safetylens.in in the address bar, allow Microphone, then tap '
              'the mic again.'
          : 'Microphone permission is off for Safety Lens. Turn it on in phone '
              'Settings → Apps → Safety Lens → Permissions.';
    case VoiceErrorKind.disabled:
      return web
          ? 'Voice input is turned off in this browser or device. On iPhone, '
              'turn on Settings → General → Keyboard → Enable Dictation. '
              'Firefox has no voice input — use Chrome, Edge or Safari.'
          : 'Voice recognition is not available on this phone. Install or '
              'enable the Google app / speech services, or type the report.';
    case VoiceErrorKind.noMic:
      return 'No microphone was found, or another app (e.g. a Webex call) is '
          'using it. Close that app and tap the mic again.';
    case VoiceErrorKind.network:
      return 'Voice input could not reach the speech service. Check the '
          'internet connection (some office networks block it), or type the '
          'report — AI will still refine it.';
    case VoiceErrorKind.language:
      return web
          ? '$langName voice input is not supported in this browser. Switch '
              'the voice language above, or type the report.'
          : '$langName voice input is not available on this phone. Install '
              'the $langName speech pack in voice/keyboard settings, or switch '
              'the voice language above.';
    case VoiceErrorKind.transient:
    case VoiceErrorKind.busy:
    case VoiceErrorKind.unknown:
      final c = (code ?? '').trim();
      return 'Voice input stopped${c.isEmpty ? '' : ' ($c)'}. Tap the mic to '
          'try again, or type the report.';
  }
}

/// For a session that ended on [DictationEnd.silence] having heard nothing.
String nothingHeardMessage({required bool web, required String langName}) =>
    web
        ? 'Didn\'t catch anything. Check the mic is unmuted, wait for '
            '"Listening", then speak in $langName — or just type it.'
        : 'Didn\'t catch anything. Wait for "Listening", then speak in '
            '$langName. If it never works, the $langName speech pack may be '
            'missing from voice/keyboard settings — or just type it.';

/// For a session that ended on [DictationEnd.micNeverStarted].
String micNeverStartedMessage({required bool web}) => web
    ? 'The microphone didn\'t start. If the browser asked for microphone '
        'access, tap Allow, then tap the mic again.'
    : 'The microphone didn\'t start. Tap the mic again; if it keeps '
        'happening, restart the app.';

/// Removes back-to-back repeated runs of words, keeping one copy. Chrome on
/// Android can return each interim step as its own result, which the plugin
/// joins: "near near cast near cast house" → "near cast house".
///
/// Applied only where that duplication happens: it would also collapse a
/// genuine "very very", which is an acceptable loss on Chrome-Android and an
/// unnecessary one elsewhere.
String collapseRepeats(String text) {
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

/// Starts one engine segment and delivers its recognised words (the whole
/// segment so far, as recognisers report it) to [onWords]. May throw.
typedef DictationListen = Future<void> Function(
    void Function(String words) onWords);

typedef DictationEnded = void Function(DictationEnd reason, bool heard);

class DictationSession {
  DictationSession({
    required this.listen,
    required this.stop,
    required this.waitIdle,
    required this.baseText,
    required this.onText,
    required this.onEnded,
    this.onLive,
    this.collapse = false,
    this.silenceLimit = const Duration(seconds: 5),
    this.startupLimit = const Duration(seconds: 12),
    this.maxDuration = const Duration(minutes: 3),
    this.restartDelay = const Duration(milliseconds: 250),
    this.maxConsecutiveFailures = 3,
    this.maxRestarts = 60,
  }) : _text = baseText;

  final DictationListen listen;
  final Future<void> Function() stop;

  /// Resolves once the engine has fully ended its previous segment. Browsers
  /// refuse to start ("recognition has already started") until then.
  final Future<void> Function() waitIdle;

  /// Field contents when the mic was tapped; dictation is appended to this.
  final String baseText;

  /// The field's new full text. Called only when it changed.
  final void Function(String text) onText;

  /// Called exactly once, synchronously, when the session ends for any reason.
  final DictationEnded onEnded;

  /// Called once, when the engine is first confirmed to be listening — the
  /// moment the worker should start speaking.
  final void Function()? onLive;

  final bool collapse;
  final Duration silenceLimit;
  final Duration startupLimit;
  final Duration maxDuration;
  final Duration restartDelay;
  final int maxConsecutiveFailures;
  final int maxRestarts;

  String _text;
  String _segmentBase = '';
  String _lastWords = '';
  bool _active = false;
  bool _live = false;
  bool _segmentListening = false;
  bool _restartPending = false;
  int _segment = 0;
  int _failures = 0;
  int _restarts = 0;
  String? _lastErrorCode;
  Timer? _silence;
  Timer? _startup;
  Timer? _cap;

  String get text => _text;
  bool get isActive => _active;
  bool get isLive => _live;
  bool get heard => _text.trim() != baseText.trim();
  int get restarts => _restarts;
  String? get lastErrorCode => _lastErrorCode;

  Future<void> start() async {
    if (_active) return;
    _active = true;
    _startup = Timer(startupLimit, () {
      if (!_live) _finish(DictationEnd.micNeverStarted);
    });
    _cap = Timer(maxDuration, () => _finish(DictationEnd.timeLimit));
    await _startSegment();
  }

  /// The worker tapped stop.
  Future<void> userStop() => _finish(DictationEnd.userStopped);

  /// End for a reason decided outside the session. [stopEngine] false when the
  /// engine already belongs to someone else (superseded).
  Future<void> end(DictationEnd reason, {bool stopEngine = true}) =>
      _finish(reason, stopEngine: stopEngine);

  Future<void> _startSegment() async {
    if (!_active) return;
    final seg = ++_segment;
    _segmentBase = _text;
    _lastWords = '';
    _segmentListening = false;
    try {
      await listen((words) {
        if (seg == _segment) _handleWords(words);
      });
    } catch (_) {
      if (!_active || seg != _segment) return;
      _failures++;
      _lastErrorCode = 'busy';
      if (_failures >= maxConsecutiveFailures) {
        _finish(DictationEnd.failed);
        return;
      }
      _scheduleRestart();
    }
  }

  /// Engine status: 'listening', 'notListening', 'done' (and 'doneNoResult').
  void handleStatus(String status) {
    if (!_active) return;
    if (status == 'listening') {
      _segmentListening = true;
      _goLive();
      return;
    }
    if (status == 'done' ||
        status == 'notListening' ||
        status == 'doneNoResult') {
      // Not yet heard listening ⇒ this end belongs to an EARLIER segment or
      // session that finished late. Acting on it is what killed fresh sessions.
      if (!_segmentListening) return;
      _segmentListening = false;
      _scheduleRestart();
    }
  }

  /// Engine error, by code.
  void handleError(String code) {
    if (!_active) return;
    _lastErrorCode = code;
    final kind = classifyVoiceError(code);
    if (_isFatal(kind)) {
      _finish(DictationEnd.failed);
      return;
    }
    if (kind != VoiceErrorKind.transient) {
      _failures++;
      if (_failures >= maxConsecutiveFailures) {
        _finish(DictationEnd.failed);
        return;
      }
    }
    _segmentListening = false;
    _scheduleRestart();
  }

  void _handleWords(String words) {
    if (!_active) return;
    _segmentListening = true; // words prove this segment is live
    _goLive();
    final spoken = (collapse ? collapseRepeats(words) : words).trim();
    if (spoken == _lastWords) return; // repeated partial while silent
    _lastWords = spoken;
    _failures = 0;
    _armSilence();
    if (spoken.isEmpty) return;
    final next = _segmentBase.trim().isEmpty
        ? spoken
        : '${_segmentBase.trimRight()} $spoken';
    if (next == _text) return;
    _text = next;
    onText(next);
  }

  void _goLive() {
    if (_live) return;
    _live = true;
    _startup?.cancel();
    _armSilence(); // the worker's five seconds start NOW, not at listen()
    onLive?.call();
  }

  void _armSilence() {
    _silence?.cancel();
    _silence = Timer(silenceLimit, () => _finish(DictationEnd.silence));
  }

  void _scheduleRestart() {
    if (!_active || _restartPending) return;
    if (_restarts >= maxRestarts) {
      _finish(DictationEnd.timeLimit);
      return;
    }
    _restartPending = true;
    _restarts++;
    final delay = restartDelay * (1 + _failures);
    Future<void>.delayed(delay, () async {
      if (!_active) {
        _restartPending = false;
        return;
      }
      await waitIdle();
      _restartPending = false;
      if (!_active) return;
      await _startSegment();
    });
  }

  Future<void> _finish(DictationEnd reason, {bool stopEngine = true}) async {
    if (!_active) return;
    _active = false;
    _silence?.cancel();
    _startup?.cancel();
    _cap?.cancel();
    _segment++; // late words from the last segment are now ignored
    onEnded(reason, heard);
    if (stopEngine) {
      try {
        await stop();
      } catch (_) {}
    }
  }
}
