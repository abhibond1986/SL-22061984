// lib/screens/near_miss_tab.dart
// v17 FIXES:
//   ✅ FIX: Voice-to-text now works on web (no permission_handler on web)
//   ✅ FIX: Visual pulsing mic indicator when listening
//   ✅ FIX: Better error handling + auto-retry on speech init
//   ✅ UI/UX: More attractive form design with better spacing & animations
//   ✅ UI/UX: Polished cards, improved visual hierarchy
//   ✅ All v16 features preserved (network check, form, duplicate detection)

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Directory;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb, Uint8List;
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../main.dart';
import '../services/gemini_vision.dart';
import '../services/network_checker.dart';
import '../services/local_db.dart';
import '../services/pdf_export.dart';
import '../services/sync_service.dart';
import '../services/admin_master_data.dart';
import '../services/geo_service.dart';
import '../services/knowledge_service.dart';
import '../widgets/analysis_progress.dart';
import '../widgets/universal_app_bar.dart';
import '../services/i18n.dart';
import '../services/groq_service.dart';
import '../services/ai_correction_service.dart';
import '../services/ai_run_log.dart';

class NearMissTab extends StatefulWidget {
  final Map<String, dynamic>? user;
  final VoidCallback? toggleTheme;
  final VoidCallback? onSignOut;
  final bool isDark;
  final bool showAppBar;
  const NearMissTab({
    super.key,
    this.user,
    this.toggleTheme,
    this.onSignOut,
    this.isDark = true,
    this.showAppBar = true,
  });
  @override
  State<NearMissTab> createState() => _NearMissTabState();
}

class _NearMissTabState extends State<NearMissTab> with TickerProviderStateMixin {
  XFile?      _pickedFile;
  Uint8List? _imageBytes;
  bool        _analyzing = false;
  String      _step      = '';
  Map<String, dynamic>? _aiBrief;
  bool        _isOnlineMode = true;

  final _brief           = TextEditingController();
  final _deptOther       = TextEditingController(); // For "Other" custom department
  final _location        = TextEditingController();
  final _description     = TextEditingController();
  final _immediateAction = TextEditingController();
  // ★ Multiple corrective actions
  final List<TextEditingController> _additionalActions = [];

  String _plant   = 'SSO Ranchi';
  String _selectedDept = '';          // Currently selected department from dropdown
  bool   _showOtherDept = false;     // Whether "Other" is selected
  String _wsaCause = '5. Equipment failure';
  String _severity = 'MEDIUM';
  String _obsType  = 'Unsafe Condition';

  String? _lastSubmissionKey;
  bool _submitting = false;
  String? _submittingAction; // tracks which button: 'save', 'share', 'pdf'
  bool _saved = false; // ★ v31: form has been saved, show "New Report" button

  // ★ v24: AI Description Refinement
  bool _aiRefining = false;
  Map<String, dynamic>? _aiSuggestion; // {refined, isNearMiss, reason, confidence}
  String? _aiSummary; // ★ Summary of Near Miss shown above description
  // ★ AI correction feedback loop: pristine snapshot of what the AI suggested
  // (description/summary, corrective action, severity) so we can diff it
  // against the user's final values on save and feed real AI mistakes back
  // into training. Null until an AI analysis populates the form.
  Map<String, String>? _aiOriginalSuggestion;
  String? _aiOriginalSource;
  // ★ v29: Proper Timer-based debounce (replaces pile-up Future.delayed)
  Timer? _descDebounce;
  Timer? _locationDebounce;
  Timer? _actionDebounce;
  static const _aiRefineDelay = Duration(seconds: 2);

  // GPS geo-tagging
  LocationData? _capturedLocation;

  final stt.SpeechToText _speech         = stt.SpeechToText();
  bool                    _speechAvailable = false;
  bool                    _isListening     = false;
  bool                    _pauseTimedOut   = false; // ★ v25: track pause-timeout vs error
  bool                    _voiceSessionEnded = false; // ★ v29: prevent double AI trigger
  int                     _voiceSessionId = 0; // ★ v29: stale timeout protection
  TextEditingController? _activeMicField;

  // ── SILENCE WATCHDOG ──────────────────────────────────────────────────────
  // `pauseFor` on speech_to_text is advisory, and on web it is routinely not
  // honoured at all: if the engine never hears a single word it often emits no
  // terminal status, so the mic stayed armed indefinitely and the AI never ran.
  // This timer is the guarantee that a dictation session always ends.
  Timer? _silenceTimer;
  static const _silenceLimit = Duration(seconds: 5);

  /// Field contents when the current session started, so the watchdog can tell
  /// "spoke, then went quiet" (hand it to the AI) from "never heard anything"
  /// (nothing to analyse — tell the user why).
  String _voiceBaseText = '';

  /// Last string the engine reported this session. Partial results repeat the
  /// same text while the user is silent, so the watchdog is only re-armed when
  /// the transcript actually GREW — otherwise a chattery engine would keep the
  /// mic alive forever and defeat the whole mechanism.
  String _lastRecognized = '';
  String                  _detectedLang    = I18n.currentLang; // input language (seed from app locale)

  // Mic pulse animation
  late AnimationController _micPulseCtrl;
  late Animation<double> _micPulse;

  // ★ v25: Voice locale map — user can pick language via long-press on mic
  // But default is now based on _selectedVoiceLang which user can toggle
  static const Map<String, String> _voiceLocaleMap = {
    'en': 'en-IN',
    'hi': 'hi-IN',   // Devanagari output — Hindi speech → Hindi text
  };

  // ★ v25: Selected voice language — starts as app language but user can change
  String _selectedVoiceLang = I18n.currentLang;

  String get _voiceLocaleId {
    return _voiceLocaleMap[_selectedVoiceLang] ?? 'hi-IN';
  }

  @override
  void initState() {
    super.initState();
    _micPulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000));
    _micPulse = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(parent: _micPulseCtrl, curve: Curves.easeInOut));
    _micPulseCtrl.repeat(reverse: true);
    _initSpeech();
    _loadMasterData();
    // Reload dropdowns the moment an admin edits a master list.
    AdminMasterData.revision.addListener(_loadMasterData);
  }

  Future<void> _loadMasterData() async {
    try {
      final plantLabels = await AdminMasterData.getPlantLabels();
      final wsa    = await AdminMasterData.getWsaCauses();
      final depts  = await AdminMasterData.getDepartments();
      final sevs   = await AdminMasterData.getSeverities();
      final obs    = await AdminMasterData.getObsTypes();
      final sevScores = await AdminMasterData.getSeverityScores();
      if (!mounted) return;
      // No .isNotEmpty guards: the admin panel is authoritative, so a list
      // the admin emptied must show as empty rather than silently keeping
      // stale values.
      setState(() {
        _plants     = plantLabels;
        _wsaCauses  = wsa;
        _departments = depts;
        _severities = sevs;
        _obsTypes   = obs;
        _severityScores = sevScores;
        // Clear selections the admin has since deleted, so the form can't
        // submit a value that no longer exists in the master list.
        if (!_plants.contains(_plant)) _plant = '';
        if (!_wsaCauses.contains(_wsaCause)) _wsaCause = '';
        if (_selectedDept.isNotEmpty && !_departments.contains(_selectedDept)) {
          _selectedDept = '';
        }
        if (!_severities.contains(_severity)) {
          _severity = _severities.isNotEmpty ? _severities.first : '';
        }
        if (!_obsTypes.contains(_obsType)) {
          _obsType = _obsTypes.isNotEmpty ? _obsTypes.first : '';
        }
      });
    } catch (_) {}
  }

  /// Get the effective department value (from dropdown or "Other" text field)
  String get _effectiveDept {
    if (_showOtherDept) return _deptOther.text.trim();
    return _selectedDept.isNotEmpty ? _selectedDept : '';
  }

  /// Set department from user profile — checks if it's in the dropdown list
  void _setDeptFromProfile(String dept) {
    if (_departments.contains(dept)) {
      _selectedDept = dept;
      _showOtherDept = false;
    } else if (dept.isNotEmpty) {
      _selectedDept = 'Other';
      _showOtherDept = true;
      _deptOther.text = dept;
    }
  }

  static bool _micPermissionGranted = false;

  // ═══════════════════════════════════════════════════════════════
  //  SILENCE WATCHDOG — 5s of nothing heard ⇒ stop mic, run AI
  // ═══════════════════════════════════════════════════════════════

  /// (Re)start the 5-second countdown. Called when a session begins and again
  /// each time the transcript actually grows, so the clock only runs against
  /// genuine silence.
  void _armSilenceWatchdog(TextEditingController field, int sessionId) {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceLimit, () => _onSilenceTimeout(field, sessionId));
  }

  void _cancelSilenceWatchdog() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Five seconds with no new words. Ends the session unconditionally, then
  /// either hands the text to the AI (the worker spoke and stopped — the normal
  /// case) or explains why nothing was captured.
  Future<void> _onSilenceTimeout(TextEditingController field, int sessionId) async {
    // Bail if this timer belongs to a session that has already moved on: the
    // user may have tapped the mic off, switched fields, or started a new
    // dictation while this callback was queued.
    if (!mounted ||
        sessionId != _voiceSessionId ||
        !_isListening ||
        _activeMicField != field) return;

    final heardSomething = field.text.trim() != _voiceBaseText.trim();

    // Both guards matter: _pauseTimedOut stops onError from auto-restarting the
    // engine behind our back, and _voiceSessionEnded stops onStatus from firing
    // the AI a second time when the plugin finally reports 'done'.
    _pauseTimedOut     = true;
    _voiceSessionEnded = true;
    _cancelSilenceWatchdog();

    try {
      await _speech.stop();
    } catch (e) {
      debugPrint('Speech stop (silence timeout) error: $e');
    }
    if (!mounted) return;
    setState(() { _isListening = false; _activeMicField = null; });

    if (heardSomething) {
      _autoRefineAfterVoice(field);
    } else {
      // Nothing at all was recognised. The likely cause differs by platform, and
      // the advice has to match: on a phone it really is usually a missing
      // on-device dictation model, but in a browser there is no "language pack"
      // to install — it is a muted/blocked mic, a noisy room, or a browser
      // without speech support. Telling a desktop user to install a keyboard
      // language pack sends them somewhere that does not exist.
      final langName = _selectedVoiceLang == 'hi' ? 'Hindi (हिंदी)' : 'English';
      _snack(
        kIsWeb
          ? 'Didn\'t catch anything. Check that the mic is unmuted and allowed for '
            'this site, then tap the mic again — or just type it, AI will still '
            'refine it in $langName.'
          : '$langName speech recognition isn\'t available on this device. '
            'Install the $langName language pack in your keyboard/voice settings, '
            'or type the report — AI will still refine it in $langName.',
        AppColors.amber,
      );
    }
  }

  /// Hand a just-dictated field to the AI. Single copy of a rule that used to be
  /// pasted in three places (manual stop, plugin 'done', silence timeout) and so
  /// drifted between them. Corrective Action is deliberately absent — a worker's
  /// stated remedy is a commitment and must not be reworded.
  void _autoRefineAfterVoice(TextEditingController field) {
    if (field == _description && _description.text.trim().length >= 10) {
      _refineWithAI(_description.text.trim());
    } else if (field == _location && _location.text.trim().length >= 5) {
      _refineFieldWithAI(_location, 'Exact Location of Incident');
    }
  }

  /// Note the transcript growing, and report whether it did. Used to decide
  /// whether the watchdog deserves a fresh 5 seconds.
  bool _noteRecognized(String words) {
    if (words == _lastRecognized) return false;
    _lastRecognized = words;
    return true;
  }

  Future<void> _initSpeech() async {
    try {
      if (!kIsWeb && !_micPermissionGranted) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          debugPrint('Speech: Microphone permission denied (status: $status)');
          if (mounted) setState(() => _speechAvailable = false);
          return;
        }
        _micPermissionGranted = true;
        debugPrint('Speech: Microphone permission granted');
      }

      _speechAvailable = await _speech.initialize(
        onError: (e) {
          debugPrint('Speech error: ${e.errorMsg} (permanent: ${e.permanent})');
          if (mounted) setState(() => _isListening = false);
          _cancelSilenceWatchdog();
          // ✅ Auto-retry on non-permanent errors (but NOT after pause-timeout)
          if (!e.permanent && _activeMicField != null && !_pauseTimedOut) {
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted && _isListening) _restartListening();
            });
          }
        },
        onStatus: (s) {
          debugPrint('Speech status: $s');
          // ★ v29: Unified handler for BOTH 'done' and 'notListening'
          // On web, pause-timeout fires 'notListening' not 'done'
          // _voiceSessionEnded guard prevents double AI trigger
          if ((s == 'done' || s == 'notListening') && _isListening && _activeMicField != null) {
            if (_voiceSessionEnded) return; // already handled
            _voiceSessionEnded = true;
            _cancelSilenceWatchdog();
            final field = _activeMicField;
            setState(() { _isListening = false; _activeMicField = null; });
            // ★ Auto-trigger AI for description & location only (not corrective action)
            if (field != null) _autoRefineAfterVoice(field);
          } else if (s == 'notListening' && mounted) {
            _cancelSilenceWatchdog();
            setState(() => _isListening = false);
          }
        },
      );
      debugPrint('Speech: initialized=$_speechAvailable');
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Speech init error: $e');
      if (mounted) setState(() => _speechAvailable = false);
    }
  }

  Future<void> _restartListening() async {
    if (!_isListening || _activeMicField == null) return;
    final field    = _activeMicField!;
    final baseText = field.text;
    _pauseTimedOut = false;
    // A retry continues the same logical dictation, so the watchdog keeps the
    // same session id — but the clock restarts, since the dropout itself is not
    // the worker's fault.
    final sessionId = _voiceSessionId;
    _voiceBaseText  = baseText;
    _lastRecognized = '';
    try {
      await Future.delayed(const Duration(milliseconds: 300));
      await _speech.listen(
        onResult: (result) {
          if (!mounted || _activeMicField != field) return;
          if (_noteRecognized(result.recognizedWords)) {
            _armSilenceWatchdog(field, sessionId);
          }
          final appended = result.recognizedWords.isEmpty
              ? baseText
              : '$baseText ${result.recognizedWords}'.trim();
          setState(() {
            field.text      = appended;
            field.selection = TextSelection.fromPosition(
                TextPosition(offset: field.text.length));
          });
          // ★ v25: Detect language from recognized words
          _detectLanguageFromText(result.recognizedWords);
        },
        localeId:     _voiceLocaleId,
        listenFor:    const Duration(minutes: 3),
        pauseFor:     const Duration(seconds: 5), // auto-stops after 5s pause → AI analysis
        partialResults: true,
        cancelOnError:  false,
        listenMode:   stt.ListenMode.dictation,
      );
      // Armed after listen() resolves, for the same reason as in _toggleVoice:
      // engine startup must not eat into the worker's five seconds.
      _armSilenceWatchdog(field, sessionId);
    } catch (e) {
      debugPrint('Speech restart error: $e');
      _cancelSilenceWatchdog();
      if (mounted) setState(() => _isListening = false);
    }
  }

  Future<void> _toggleVoice([TextEditingController? field]) async {
    final targetField = field ?? _location;

    // If already listening on the same field, stop
    if (_isListening && _activeMicField == targetField) {
      _voiceSessionEnded = true; // prevent double AI from onStatus
      _cancelSilenceWatchdog();
      await _speech.stop();
      setState(() { _isListening = false; _activeMicField = null; });
      // ★ v28: AI correction for description & location only (not corrective action)
      _autoRefineAfterVoice(targetField);
      return;
    }

    // If listening on a different field, stop first
    if (_isListening) {
      _voiceSessionEnded = true;
      _cancelSilenceWatchdog();
      await _speech.stop();
      setState(() { _isListening = false; _activeMicField = null; });
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // ★ v29: Reset session guard for new voice session
    _voiceSessionEnded = false;
    _voiceSessionId++;

    // Check availability — re-init if needed
    if (!_speechAvailable) {
      await _initSpeech();
      if (!_speechAvailable) {
        if (mounted) {
          _snack(
            kIsWeb
              ? 'Voice input requires a supported browser (Chrome, Edge). Please allow microphone access when prompted.'
              : 'Microphone unavailable. Please check app permissions in Settings.',
            AppColors.amber,
          );
        }
        return;
      }
    }

    final baseText = targetField.text;
    _activeMicField = targetField;
    _pauseTimedOut = false;
    _voiceBaseText  = baseText;
    _lastRecognized = '';
    final sessionId = _voiceSessionId;
    debugPrint('Speech: Starting with locale=${_voiceLocaleId} (selectedVoiceLang=$_selectedVoiceLang)');
    try {
      setState(() => _isListening = true);
      await _speech.listen(
        onResult: (result) {
          if (!mounted || _activeMicField != targetField) return;
          final words = result.recognizedWords;
          // Re-arm on real progress only. Repeated identical partials mean the
          // worker has gone quiet even though callbacks keep arriving.
          if (_noteRecognized(words)) {
            _armSilenceWatchdog(targetField, sessionId);
          }
          if (words.isEmpty) return;
          final appended = baseText.isEmpty ? words : '$baseText $words';
          setState(() {
            targetField.text      = appended.trim();
            targetField.selection = TextSelection.fromPosition(
                TextPosition(offset: targetField.text.length));
          });
          // ★ v25: Detect language from recognized words
          _detectLanguageFromText(words);
        },
        localeId:       _voiceLocaleId,
        listenFor:      const Duration(minutes: 3),
        pauseFor:       const Duration(seconds: 5), // auto-stops after 5s pause → AI analysis
        partialResults: true,
        cancelOnError:  false,
        listenMode:     stt.ListenMode.dictation,
      );
      // The clock starts HERE, only once listen() has actually resolved — not
      // before the call. `listen()` does not return until the engine is up, and
      // on web that includes the browser's "Allow microphone?" prompt, which the
      // worker may take several seconds to click. Arming earlier meant the five
      // seconds could elapse during permission/startup and the mic was killed
      // before it had ever been able to hear a word. The user's five seconds are
      // five seconds of *listening*, not of waiting.
      //
      // This is still ahead of any onResult callback, so the case the watchdog
      // exists for — an engine that never reports anything at all — is caught.
      // (It also replaces an older 8-second "locale not installed" probe that
      // used to sit here, so there is one timer now instead of two racing ones.)
      _armSilenceWatchdog(targetField, sessionId);
    } catch (e) {
      debugPrint('Speech listen error: $e');
      _cancelSilenceWatchdog();
      if (mounted) setState(() { _isListening = false; _activeMicField = null; });
      _snack('Voice input failed. Try again.', AppColors.red);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v25: AUTO LANGUAGE DETECTION from speech input
  //  Detects Hindi or English based on Unicode ranges
  // ═══════════════════════════════════════════════════════════════
  void _detectLanguageFromText(String text) {
    if (text.trim().isEmpty) return;
    int devanagari = 0, latin = 0;
    for (final c in text.runes) {
      if (c >= 0x0900 && c <= 0x097F) devanagari++;      // Hindi/Devanagari
      else if (c >= 0x0041 && c <= 0x007A) latin++;      // English (ASCII letters)
    }
    // Any Devanagari present ⇒ Hindi (mixed input is common; even a few
    // Hindi characters mean the worker is writing in Hindi).
    if (devanagari > 0) {
      _detectedLang = 'hi';
      return;
    }
    // If the user explicitly chose Hindi as their voice/input language, honour
    // that even before any Hindi characters are typed — the AI must reply in
    // Hindi. Only fall to English when there IS latin text and Hindi wasn't chosen.
    if (_selectedVoiceLang == 'hi') {
      _detectedLang = 'hi';
      return;
    }
    if (latin > 0) _detectedLang = 'en';
  }

  /// Get language name for AI prompt
  String get _detectedLangName {
    switch (_detectedLang) {
      case 'hi': return 'Hindi';
      default: return 'English';
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v24/v25: AI NEAR MISS REFINEMENT
  //  Validates whether input is a genuine near miss & refines language
  // ═══════════════════════════════════════════════════════════════
  void _onDescriptionChanged(String text) {
    // ★ v29: Detect language as user types
    _detectLanguageFromText(text);
    // Clear previous suggestion if user is still editing
    if (_aiSuggestion != null) {
      setState(() => _aiSuggestion = null);
    }
    // ★ v29: Proper Timer debounce — cancels previous, only fires once
    _descDebounce?.cancel();
    if (text.trim().length >= 10) {
      _descDebounce = Timer(_aiRefineDelay, () {
        if (!mounted) return;
        if (_description.text.trim() == text.trim()) {
          _refineWithAI(text.trim());
        }
      });
    }
  }

  void _onLocationChanged(String text) {
    _detectLanguageFromText(text);
    _locationDebounce?.cancel();
    if (text.trim().length >= 5) {
      _locationDebounce = Timer(_aiRefineDelay, () {
        if (!mounted) return;
        if (_location.text.trim() == text.trim()) {
          _refineFieldWithAI(_location, 'Exact Location of Incident');
        }
      });
    }
  }

  void _onActionChanged(String text) {
    // ★ No auto-AI correction for corrective action — user writes their own actions
    _detectLanguageFromText(text);
  }

  /// ★ v28/v29: AI correction for any text field (location, immediate action)
  /// Uses Groq (primary) → Apps Script (fallback) for reliability
  bool _fieldRefining = false; // ★ v29: mutex for field refinement
  Future<void> _refineFieldWithAI(TextEditingController field, String fieldLabel) async {
    final rawText = field.text.trim();
    if (rawText.length < 5 || _aiRefining || _fieldRefining) return;
    _fieldRefining = true;

    _detectLanguageFromText(rawText);

    // Same pattern as _refineWithAI: capture outcome, record once in `finally`.
    final sw = Stopwatch()..start();
    var fieldOk = false;
    var fieldProvider = '';
    var fieldReason = AiRunLog.reasonExhausted;

    try {
      // ★ PRIMARY: Try Groq first (fast, free, reliable)
      final groqResult = await GroqService.correctText(
        text: rawText,
        fieldLabel: fieldLabel,
        language: _detectedLangName,
      ).timeout(const Duration(seconds: 12), onTimeout: () => null);

      if (groqResult != null && groqResult.isNotEmpty && groqResult != rawText) {
        fieldOk = true;
        fieldProvider = 'groq';
        if (mounted) {
          setState(() {
            field.text = groqResult;
            field.selection = TextSelection.fromPosition(TextPosition(offset: groqResult.length));
          });
        }
        return;
      }
      if (sw.elapsedMilliseconds >= 12000) fieldReason = AiRunLog.reasonTimeout;

      if (!mounted) return;

      // ★ FALLBACK: Apps Script (Gemini) if Groq fails
      final langInstruction = _detectedLang == 'en'
          ? 'Respond in English.'
          : 'IMPORTANT: Respond in $_detectedLangName language using native script. Do NOT translate to English.';

      final prompt = '''You are a safety report text corrector for SAIL (Steel Authority of India Limited).

FIELD: $fieldLabel
WORKER'S INPUT: "$rawText"

$langInstruction

Correct this text for:
- Grammar and spelling
- Safety terminology (use proper industrial safety terms)
- Clarity and conciseness
- Professional tone appropriate for an official near-miss report

Respond with ONLY the corrected text — no quotes, no explanation, no JSON. Just the improved text.
If the text is already fine, return it unchanged.''';

      Map<String, dynamic>? body = await SyncService.callAiText(prompt);
      var viaDirectFallback = false;
      if (body == null) {
        body = await _callAiTextFallback(prompt);
        viaDirectFallback = true;
      }
      if (!mounted || body == null) return;

      String? aiText;
      if (body['text'] != null) aiText = body['text'].toString();
      else if (body['result'] != null) aiText = body['result'].toString();

      if (aiText != null && aiText.trim().isNotEmpty) {
        fieldOk = true;
        fieldProvider =
            viaDirectFallback ? 'apps_script_direct' : 'apps_script';
        String cleaned = aiText.trim();
        if (cleaned.startsWith('```')) cleaned = cleaned.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll('```', '');
        if (cleaned.startsWith('"') && cleaned.endsWith('"')) cleaned = cleaned.substring(1, cleaned.length - 1);
        cleaned = cleaned.trim();

        if (cleaned.isNotEmpty && cleaned != rawText) {
          setState(() {
            field.text = cleaned;
            field.selection = TextSelection.fromPosition(TextPosition(offset: cleaned.length));
          });
        }
      } else {
        // Replied, but with nothing usable.
        fieldOk = false;
        fieldReason = AiRunLog.reasonEmptyResult;
      }
    } catch (_) {
      fieldReason = AiRunLog.reasonException;
    }
    finally {
      _fieldRefining = false; // ★ v29: always release mutex
      AiRunLog.record(
        runType: AiRunLog.typeFieldRefine,
        outcome: fieldOk ? AiRunLog.outcomeSuccess : AiRunLog.outcomeFailed,
        failReason: fieldOk ? '' : fieldReason,
        provider: fieldProvider,
        durationMs: sw.elapsedMilliseconds,
        plant: _plant,
        dept: _effectiveDept,
      );
    }
  }

  Future<void> _refineWithAI(String rawText) async {
    if (_aiRefining || rawText.length < 10) return;
    setState(() => _aiRefining = true);

    // TELEMETRY: this method has three exits (Groq success, Apps Script
    // success, silent fall-through) plus a catch-all. Rather than a log call at
    // each — where one is easy to miss and the fall-through path had no
    // handling at all — the outcome is captured in locals and recorded once in
    // `finally`, which every path must pass through.
    final sw = Stopwatch()..start();
    var refineOk = false;
    var refineProvider = '';
    var refineReason = AiRunLog.reasonExhausted;

    try {
      // ★ v29: Detect language from the raw text before sending to AI
      _detectLanguageFromText(rawText);

      // ★ v29: Get KB context with timeout to prevent hanging.
      // maxKbDocs raised from 2 and the timeout from 3s: this is a text
      // classification, so uploaded documents are the main thing that makes
      // the suggestion plant-specific rather than generic.
      String kbContext = '';
      try {
        kbContext = await KnowledgeService.getContextForPrompt(rawText,
                maxKbDocs: 4, snippetChars: 600)
            .timeout(const Duration(seconds: 6), onTimeout: () => '');
      } catch (_) {}

      if (!mounted) return;

      // ★ v29 PRIMARY: Try Groq first with timeout (fast, free, reliable)
      final groqResult = await GroqService.classifyNearMiss(
        text: rawText,
        language: _detectedLangName,
        kbContext: kbContext,
      ).timeout(const Duration(seconds: 15), onTimeout: () => null);

      if (groqResult != null && mounted) {
        refineOk = true;
        refineProvider = 'groq';
        setState(() {
          _aiSuggestion = groqResult;
          _aiRefining = false;
        });
        return;
      }
      // Groq returned null — either a genuine failure or the 15s timeout above.
      // Recorded as a timeout only if we actually spent that long, so a fast
      // rejection isn't mislabelled as a slow network.
      if (sw.elapsedMilliseconds >= 15000) refineReason = AiRunLog.reasonTimeout;

      if (!mounted) return;

      // ★ FALLBACK: Apps Script (Gemini) if Groq fails
      final langInstruction = _detectedLang == 'en'
          ? 'Respond with the "reason", "refined", and "correctiveAction" fields in English.'
          : 'IMPORTANT: The worker spoke in $_detectedLangName. You MUST write the "reason", "refined", and "correctiveAction" fields in $_detectedLangName language (using native script). Do NOT translate to English.';

      // Frame the knowledge bank as authoritative, and drive "category" from
      // the admin's own observation types. This prompt previously dumped the KB
      // in unlabelled and hardcoded five categories ("Unsafe Act, Unsafe
      // Condition, Near Miss, Equipment Failure, Process Deviation") that do
      // not match this form's own dropdown — so the AI could suggest a category
      // the form then refused to accept.
      final kbTrimmed = kbContext.trim();
      final kbBlock = kbTrimmed.isEmpty
          ? ''
          : 'PLANT SAFETY KNOWLEDGE (uploaded by this plant\'s safety admin — '
              'AUTHORITATIVE. Where it conflicts with your general knowledge, '
              'follow it, and cite clause/section numbers exactly as written):\n'
              '$kbTrimmed\n\n';
      final categoryRule = _obsTypes.isEmpty
          ? '"category": ""'
          : '"category": "one of (exact wording): ${_obsTypes.join(', ')}"';

      final prompt = '''$kbBlock
You are analyzing a potential near miss incident reported by a worker at SAIL (Steel Authority of India Limited).

WORKER'S INPUT: "$rawText"

$langInstruction

Analyze this and respond in STRICT JSON format:
{
  "isNearMiss": true/false,
  "confidence": 0-100,
  "reason": "brief explanation why this is or is not a near miss (in the same language as worker's input)",
  "refined": "rewritten professional near-miss description with proper safety terminology, clear grammar, and structured format (in the same language as worker's input)",
  "correctiveAction": "specific corrective action to prevent recurrence — practical, actionable steps (in the same language as worker's input)",
  $categoryRule,
  "detectedLanguage": "the language the worker spoke in (English/Hindi)"
}

CORRECTIVE ACTION GUIDANCE:
- Be specific and actionable (e.g., "Install guardrail at platform edge" not just "Fix the issue")
- Reference applicable safety measures (barricading, signage, PPE, LOTO, PTW)
- Include both immediate action AND preventive measure where applicable
- Keep it concise (1-2 sentences)

NEAR MISS DEFINITION: An unplanned event that DID NOT result in injury/illness/damage but HAD THE POTENTIAL to do so. It involves an unexpected hazardous exposure, a close call, or a condition that could lead to an accident.

NOT A NEAR MISS: routine observations, planned maintenance, general complaints, requests, work orders, or situations with no potential for harm.

If the input does NOT qualify as a near miss, set isNearMiss=false and clearly explain in "reason" (in the worker's language) why their description does not match the definition of a near miss.

Respond ONLY with the JSON — no explanations outside JSON.''';

      Map<String, dynamic>? body = await SyncService.callAiText(prompt);
      var viaDirectFallback = false;
      if (body == null) {
        body = await _callAiTextFallback(prompt);
        viaDirectFallback = true;
      }
      if (!mounted) return;

      if (body != null) {
        String? aiText;
        if (body['text'] != null) {
          aiText = body['text'].toString();
        } else if (body['result'] != null) {
          aiText = body['result'].toString();
        } else {
          aiText = jsonEncode(body);
        }

        if (aiText != null) {
          String jsonStr = aiText;
          final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(jsonStr);
          if (jsonMatch != null) jsonStr = jsonMatch.group(0)!;

          try {
            final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
            refineOk = true;
            refineProvider =
                viaDirectFallback ? 'apps_script_direct' : 'apps_script';
            if (mounted) {
              setState(() {
                _aiSuggestion = parsed;
                _aiRefining = false;
              });
            }
            return;
          } catch (_) {
            // The model replied but not with usable JSON. That is a model
            // quality problem, not an outage, so it must not be filed under
            // connectivity failures.
            refineReason = AiRunLog.reasonEmptyResult;
          }
        }
      }
    } catch (_) {
      refineReason = AiRunLog.reasonException;
    }
    // ★ v29: ALWAYS reset _aiRefining — prevents stuck state
    finally {
      if (mounted && _aiRefining) setState(() => _aiRefining = false);
      AiRunLog.record(
        runType: AiRunLog.typeNearMissText,
        outcome: refineOk ? AiRunLog.outcomeSuccess : AiRunLog.outcomeFailed,
        failReason: refineOk ? '' : refineReason,
        provider: refineProvider,
        durationMs: sw.elapsedMilliseconds,
        plant: _plant,
        dept: _effectiveDept,
      );
    }
  }

  /// ★ v25: Fallback AI text call using GeminiVision's backend directly
  Future<Map<String, dynamic>?> _callAiTextFallback(String prompt) async {
    try {
      const backendUrl = 'https://script.google.com/macros/s/AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1HyDrgXtYflGfmqJRH9wnZZusj5GqX9frCx64rkd61Rg/exec';
      final body = jsonEncode({'action': 'gemini', 'prompt': prompt});
      final resp = await http.post(
        Uri.parse(backendUrl),
        body: body,
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        // ★ v29 FIX: Force UTF-8 decode for non-English text
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map<String, dynamic>) return decoded;
      }
      // Handle redirect (mobile)
      if (resp.statusCode == 302 || resp.statusCode == 301) {
        final redirectUrl = resp.headers['location'];
        if (redirectUrl != null) {
          final getResp = await http.get(Uri.parse(redirectUrl)).timeout(const Duration(seconds: 15));
          if (getResp.statusCode == 200) {
            final decoded = jsonDecode(utf8.decode(getResp.bodyBytes));
            if (decoded is Map<String, dynamic>) return decoded;
          }
        }
      }
    } catch (e) {
      debugPrint('AI fallback error: $e');
    }
    return null;
  }

  void _acceptAiRefinement() {
    if (_aiSuggestion == null) return;
    final refined = _aiSuggestion!['refined']?.toString() ?? '';
    final correctiveAction = _aiSuggestion!['correctiveAction']?.toString() ?? '';
    if (refined.isNotEmpty) {
      // Generate a 1-2 line summary from the refined text
      final summary = _generateSummary(refined);
      setState(() {
        _description.text = refined;
        _description.selection = TextSelection.fromPosition(
            TextPosition(offset: refined.length));
        _aiSummary = summary;
        // ★ v35: Also populate corrective action if AI suggested one
        if (correctiveAction.isNotEmpty && _immediateAction.text.trim().isEmpty) {
          _immediateAction.text = correctiveAction;
          _immediateAction.selection = TextSelection.fromPosition(
              TextPosition(offset: correctiveAction.length));
        }
        // ★ Snapshot AI's refinement so later user edits can be detected.
        _aiOriginalSuggestion = {
          'summary':          refined,
          'correctiveAction': correctiveAction,
          'severity':         _severity,
        };
        _aiOriginalSource = _aiSuggestion?['_source']?.toString() ?? 'refinement';
        _aiSuggestion = null;
      });
    }
  }

  /// Generate a concise 1-line summary from description text
  String _generateSummary(String text) {
    // Take first sentence or first 100 chars as summary
    final sentences = text.split(RegExp(r'[.।]'));
    if (sentences.isNotEmpty && sentences[0].trim().length > 10) {
      final first = sentences[0].trim();
      return first.length > 120 ? '${first.substring(0, 117)}...' : first;
    }
    return text.length > 120 ? '${text.substring(0, 117)}...' : text;
  }

  void _dismissAiSuggestion() {
    setState(() => _aiSuggestion = null);
  }

  /// ★ v34: Compute risk score from severity for manual entries.
  /// Uses the ADMIN-CONFIGURED severity scores (Admin ▸ Custom Lists ▸
  /// severity scoring) so editing a score in the admin panel changes the
  /// score recorded here. Previously this method hardcoded a second,
  /// contradictory scale (90/70/50/25) that ignored the admin entirely.
  /// `_severityScores` is loaded by _loadMasterData(); the fallback is the
  /// shared default map, never a locally-invented scale.
  int _computeRiskScore(String severity) {
    final scores = _severityScores.isNotEmpty
        ? _severityScores
        : AdminMasterData.defaultSeverityScores;
    // Via the shared helper so this screen and the AI scan tab cannot disagree
    // about an unknown label. The old local fallback ended in 0, which filed a
    // hazard with a renamed severity as harmless; the helper falls back to the
    // middle of the scale instead.
    return AdminMasterData.scoreFromMap(scores, severity);
  }

  String? _generateThumbnail(Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;
      final thumb = img.copyResize(decoded, width: 60);
      final jpgBytes = img.encodeJpg(thumb, quality: 50);
      return base64Encode(jpgBytes);
    } catch (e) {
      print('Thumbnail generation failed: $e');
      return null;
    }
  }

  /// ★ v31: Generate medium-quality image for sharing (PDF/WhatsApp)
  /// 400px wide, quality 75 — good enough for reports, won't blow up storage
  String? _generateShareImage(Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;
      // Only resize if larger than 400px wide
      final resized = decoded.width > 400
          ? img.copyResize(decoded, width: 400)
          : decoded;
      final jpgBytes = img.encodeJpg(resized, quality: 75);
      return base64Encode(jpgBytes);
    } catch (e) {
      return null;
    }
  }

  Future<void> _uploadPdfBackground(Map<String, dynamic> incident, Map<String, dynamic>? user, [Uint8List? imgBytes]) async {
    try {
      final pdfBytes = await PdfExport.generateIncidentReportBytes(
        incident:     incident,
        reporterName: user?['name']?.toString() ?? 'SAIL Safety Officer',
        reporterPno:  user?['pno']?.toString()  ?? '',
        imageBytes:   imgBytes,
      );
      if (pdfBytes.isEmpty) return;
      final url = await SyncService.uploadPdfToDrive(
        incidentId: incident['id']?.toString() ?? '',
        pdfBytes:   pdfBytes,
        fileName:   'SafetyLens_${incident['id']}.pdf',
      );
      if (url != null && url.isNotEmpty) {
        await SyncService.pushIncident({...incident, 'pdfUrl': url}).catchError((_) => false);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _descDebounce?.cancel();
    _locationDebounce?.cancel();
    _actionDebounce?.cancel();
    _silenceTimer?.cancel();
    _micPulseCtrl.dispose();
    _speech.cancel();
    AdminMasterData.revision.removeListener(_loadMasterData);
    _brief.dispose(); _deptOther.dispose(); _location.dispose();
    _description.dispose(); _immediateAction.dispose();
    for (final c in _additionalActions) { c.dispose(); }
    super.dispose();
  }

  // SINGLE SOURCE OF TRUTH: AdminMasterData for all three lists. Seeded from
  // the shared consts (references, never re-typed copies) so the first frame
  // has something to paint; _loadMasterData() replaces them immediately.
  // Uses the same plantLabel() formatter as every other screen so the plant
  // stored on an incident matches what the dashboards group by.
  List<String> _plants = AdminMasterData.sailPlants
      .map(AdminMasterData.plantLabel)
      .where((s) => s.isNotEmpty)
      .toList();
  List<String> _departments = List<String>.from(AdminMasterData.defaultDepartments);
  List<String> _wsaCauses = List<String>.from(AdminMasterData.defaultWsaCauses);
  List<String> _severities = List<String>.from(AdminMasterData.defaultSeverities);
  List<String> _obsTypes = List<String>.from(AdminMasterData.defaultObservationTypes);
  Map<String, int> _severityScores =
      Map<String, int>.from(AdminMasterData.defaultSeverityScores);

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 80, maxWidth: 1024, maxHeight: 1024);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _pickedFile = picked; _imageBytes = bytes;
      _aiBrief = null;
    });

    // ★ v32: Try EXIF GPS first (more accurate for gallery photos — exact capture location)
    // Then fall back to device GPS if EXIF has no location
    _extractLocationFromImage(bytes, source);

    // Ask user: scan with AI or just upload?
    if (!mounted) return;
    final shouldScan = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Image Captured', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: const Text('Do you want AI to scan this image for hazards, or just attach it?',
            style: TextStyle(fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Just Attach', style: TextStyle(fontSize: 12)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.auto_fix_high, size: 14),
            label: const Text('AI Scan', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)),
          ),
        ],
      ),
    );

    if (shouldScan == true) {
      setState(() => _analyzing = true);
      await _analyzeImage();
    }
  }

  /// ★ v32: Extract location from EXIF or device GPS
  /// For gallery photos: tries EXIF first (captures where photo was TAKEN)
  /// For camera photos: uses device GPS (real-time location)
  Future<void> _extractLocationFromImage(Uint8List imageBytes, ImageSource source) async {
    if (source == ImageSource.gallery) {
      // Gallery: try EXIF first — it tells us WHERE the photo was originally taken
      try {
        final exifLocation = await GeoService.getLocationFromExif(imageBytes).timeout(
          const Duration(seconds: 5),
          onTimeout: () => null,
        );
        if (!mounted) return;
        if (exifLocation != null && exifLocation.isValid) {
          _capturedLocation = exifLocation;
          if (_location.text.isEmpty || _location.text == 'To be confirmed (edit if needed)') {
            final address = GeoService.getDisplayAddress(exifLocation);
            if (address.isNotEmpty) {
              setState(() => _location.text = address);
            } else {
              // No address but have coords — show coords
              setState(() => _location.text =
                '${exifLocation.latitude!.toStringAsFixed(5)}, ${exifLocation.longitude!.toStringAsFixed(5)}');
            }
          }
          return; // EXIF worked — don't need device GPS
        }
      } catch (_) {}
    }
    // Camera photos or EXIF extraction failed — use device GPS
    _captureGpsInBackground();
  }

  /// Captures GPS location silently and fills location field with place name
  Future<void> _captureGpsInBackground() async {
    try {
      final location = await GeoService.getCurrentLocation().timeout(
        const Duration(seconds: 8),
        onTimeout: () => LocationData(error: 'GPS timeout'),
      );
      if (!mounted) return;
      if (location != null && location.isValid) {
        _capturedLocation = location;
        // ★ v29 FIX: Only fill location if user hasn't typed anything
        if (_location.text.isEmpty || _location.text == 'To be confirmed (edit if needed)') {
          final address = GeoService.getDisplayAddress(location);
          if (address.isNotEmpty) {
            setState(() => _location.text = address);
          }
        }
      }
    } catch (_) {
      // GPS capture failed silently — user can fill manually
    }
  }

  Map<String, dynamic> _applyHardenedV15Filters(String name, String desc, String action, String reg, String cause) {
    final n = name.toLowerCase();
    final d = desc.toLowerCase();

    bool isLikelyTubeOrConduit = n.contains('wire') || n.contains('cable') || n.contains('electrical');
    bool hasPipingContext = d.contains('pipe') || d.contains('bracket') || d.contains('oxygen') || d.contains('manifold') || d.contains('support') || d.contains('tube');

    if (isLikelyTubeOrConduit && hasPipingContext) {
      return {
        'name': 'Small-bore process tubing / conduit',
        'desc': 'Small diameter instrumentation line, impulse line, or process tubing tracking along the primary structural bracket alignment. Safe fixed configuration.',
        'action': 'Maintain standard periodic mechanical integrity checks on pipes and structural bracket elements.',
        'reg': 'FA 1948 S39 (Equipment Integrity & Inspection)',
        'cause': 'Equipment failure',
        'obsType': 'Unsafe Condition'
      };
    }
    return {'name': name, 'desc': desc, 'action': action, 'reg': reg, 'cause': cause, 'obsType': _obsType};
  }

  Future<void> _analyzeImage() async {
    final networkStatus = await NetworkChecker.getNetworkStatus();

    if (!networkStatus['hasInternet']!) {
      // Recorded here because this path returns BEFORE GeminiVision is called,
      // so the instrumentation inside it never sees this run. Without this the
      // dashboard would under-report exactly the failures caused by shop-floor
      // connectivity — the most common kind.
      AiRunLog.record(
        runType: AiRunLog.typeNearMissImage,
        outcome: AiRunLog.outcomeFailed,
        failReason: AiRunLog.reasonNoInternet,
        plant: _plant,
        dept: _effectiveDept,
      );
      _snack('Offline - Image analysis skipped. Fill form manually.', const Color(0xFFD97706));
      setState(() {
        _isOnlineMode = false;
        _aiBrief = {
          'identified': 'Manual entry — Offline',
          'statutory':  'Complete form manually',
          'type':       'Unsafe Condition',
          'severity':   'MEDIUM',
          'confidence': 0,
          // Hardcoded rather than read from a result: this path returns before
          // GeminiVision runs, so there is no result to read — but the cause is
          // known for certain here, which is exactly why it is worth saying.
          'offlineReason': 'this device has no internet connection',
          'offlineHint':   'The photo is saved with the report. Fill the form '
              'manually now, or delete and re-scan once you are back online.',
        };
        _brief.text = 'Describe the near miss observed.';
        _analyzing  = false;
      });
      return;
    }

    // ✅ FIXED: Removed backend reachability pre-check that always failed on Android
    // The actual GeminiVision call has its own retry logic and will fallback if needed

    final steps = ['Uploaded', 'Analyzing image...', 'Classifying hazard...', 'Pre-filling form...'];
    for (var i = 0; i < steps.length - 1; i++) {
      setState(() => _step = steps[i]);
      await Future.delayed(const Duration(milliseconds: 700));
    }
    try {
      setState(() => _step = steps.last);
      // runType/plant/dept are passed so the ONE instrumentation point inside
      // GeminiVision can attribute this run to near-miss rather than to a
      // hazard scan. The three 700ms fake-progress delays above are outside the
      // measured window (the Stopwatch starts inside analyseImageBytes), so
      // they do not inflate the reported response time.
      Map<String, dynamic>? result = kIsWeb
          ? await GeminiVision.analyseImageBytes(_imageBytes!,
              runType: AiRunLog.typeNearMissImage,
              plant: _plant,
              dept: _effectiveDept)
          : await GeminiVision.analyseImage(File(_pickedFile!.path),
              runType: AiRunLog.typeNearMissImage,
              plant: _plant,
              dept: _effectiveDept);

      final hazards = (result?['hazards'] as List?) ?? [];
      final isOnline = result?['_isOnline'] == true;

      // ✅ FIX: If AI failed (offline/exhausted) with no hazards, show clean message
      if (hazards.isEmpty && !isOnline) {
        final user = await LocalDB.getCurrentUser();
        setState(() {
          _isOnlineMode = false;
          _aiBrief = {
            'identified': 'AI unavailable — fill form manually',
            'statutory':  'Refer applicable regulations',
            'type':       'Unsafe Condition',
            'severity':   'MEDIUM',
            'confidence': 0,
            // This is THE offline path for near-miss photos: every fallback
            // returns no hazards and _isOnline false, so it lands here rather
            // than in the map further down. The cause has to be carried on this
            // map or the banner can only ever say "AI could not analyze image".
            'offlineReason': result?['_offline_reason']?.toString() ?? '',
            'offlineHint':   result?['_offline_hint']?.toString() ?? '',
          };
          _brief.text       = '';
          _setDeptFromProfile(user?['department']?.toString() ?? 'Operations');
          if (_location.text.isEmpty || _location.text == 'To be confirmed (edit if needed)') {
            if (_capturedLocation != null && _capturedLocation!.isValid) {
              _location.text = GeoService.getDisplayAddress(_capturedLocation!);
            } else {
              _location.text = 'To be confirmed (edit if needed)';
            }
          }
          _analyzing = false;
        });
        return;
      }

      // ✅ FIX: Safely access first hazard — guard against null/non-Map entries
      Map<String, dynamic>? first;
      if (hazards.isNotEmpty && hazards.first is Map) {
        try {
          first = Map<String, dynamic>.from(hazards.first as Map);
        } catch (_) {
          first = null;
        }
      }

      String rawName   = first?['name']?.toString() ?? 'Near miss observed';
      String rawDesc   = first?['description']?.toString() ?? result?['summary']?.toString() ?? '';
      String rawAction = first?['correctiveAction']?.toString() ?? '';
      String rawReg    = first?['regulation']?.toString() ?? '';
      String rawCause  = _mapToWsaCause(first?['category']?.toString() ?? '', rawName);

      final refinedData = _applyHardenedV15Filters(rawName, rawDesc, rawAction, rawReg, rawCause);

      final sev        = (first?['severity']?.toString() ?? 'MEDIUM').toUpperCase();
      // isOnline already declared above (line ~381)

      final user              = await LocalDB.getCurrentUser();
      String plantFromProfile = user?['plant']?.toString() ?? _plant;
      if (!_plants.contains(plantFromProfile)) plantFromProfile = _plant;

      setState(() {
        _isOnlineMode = isOnline;
        _aiBrief = {
          'identified': refinedData['name'],
          'statutory':  (refinedData['reg']?.toString() ?? '').isEmpty ? 'Refer Factories Act S35-41' : refinedData['reg'].toString(),
          'type':       refinedData['obsType'],
          'severity':   sev,
          'confidence': result?['confidence'] ?? 75,
          'isOnline':   isOnline,
          // Carried through so the banner below can name the ACTUAL cause of an
          // offline result (spent daily allowance, rejected key, throttle, no
          // internet) instead of always blaming connectivity. GeminiVision sets
          // these on every fallback; they are absent on a successful analysis.
          'offlineReason': result?['_offline_reason']?.toString() ?? '',
          'offlineHint':   result?['_offline_hint']?.toString() ?? '',
        };
        _brief.text           = '${refinedData['name'] ?? ''}. ${refinedData['desc'] ?? ''}'.trim();
        _description.text     = refinedData['desc']?.toString() ?? '';
        _immediateAction.text = refinedData['action']?.toString() ?? '';
        _setDeptFromProfile(user?['department']?.toString() ?? 'Operations');
        // Only set placeholder if GPS hasn't already filled it
        if (_location.text.isEmpty || _location.text == 'To be confirmed (edit if needed)') {
          if (_capturedLocation != null && _capturedLocation!.isValid) {
            _location.text = GeoService.getDisplayAddress(_capturedLocation!);
          } else {
            _location.text = 'To be confirmed (edit if needed)';
          }
        }
        _plant                = plantFromProfile;
        _wsaCause             = refinedData['cause']?.toString() ?? _wsaCause;
        _severity             = sev;
        _obsType              = refinedData['obsType']?.toString() ?? _obsType;
        _analyzing            = false;
        // ★ Snapshot the AI's suggested values so we can detect user edits.
        _aiOriginalSuggestion = {
          'summary':          refinedData['desc']?.toString() ?? '',
          'correctiveAction': refinedData['action']?.toString() ?? '',
          'severity':         sev,
        };
        _aiOriginalSource = (result?['_source'] ?? (isOnline ? 'online' : 'offline')).toString();
      });
    } catch (e) {
      setState(() {
        _isOnlineMode = false;
        _aiBrief = {
          'identified': 'Manual entry — Analysis failed',
          'statutory':  'Complete form manually',
          'type':       'Unsafe Condition',
          'severity':   'MEDIUM',
          'confidence': 0,
          // Deliberately does NOT include e.toString(): a Dart exception string
          // tells a shop-floor reporter nothing and looks like a broken app.
          'offlineReason': 'the scan hit an unexpected error',
          'offlineHint':   'Fill the form manually. If this keeps happening, '
              'report it to the Safety Lens administrator.',
        };
        _brief.text = 'Describe the near miss observed.';
        _analyzing  = false;
      });
    }
  }

  String _mapToWsaCause(String category, String name) {
    final c = category.toUpperCase();
    final n = name.toLowerCase();
    if (c == 'HEIGHT'    || n.contains('fall') || n.contains('height'))  return 'Fall from Height';
    if (c == 'ELECTRICAL'|| n.contains('electric'))                      return 'Electrical';
    if (c == 'HOT_WORK'  || n.contains('hot')  || n.contains('weld'))   return 'Burn / Fire';
    if (c == 'GAS'       || n.contains('gas'))                           return 'Gas Related';
    if (c == 'MACHINERY' || n.contains('machine') || n.contains('crane'))return 'Machine / Equipment';
    if (c == 'HOUSEKEEPING'|| n.contains('spill') || n.contains('slip')) return 'Slip / Fall';
    return 'Other';
  }

  String _buildSubmissionKey() {
    final title = (_aiBrief?['identified']?.toString() ?? _brief.text.split('.').first).trim().toLowerCase();
    final loc   = _location.text.trim().toLowerCase();
    final now   = DateTime.now();
    final bucket = '${now.year}${now.month}${now.day}${now.hour}${now.minute ~/ 5}';
    return '${_plant}|$loc|$title|$bucket';
  }

  Future<bool> _checkDuplicate() async {
    final key = _buildSubmissionKey();
    if (_lastSubmissionKey == key) {
      _snack('This exact report was just submitted.', const Color(0xFFD97706));
      return true;
    }
    final existing = await LocalDB.getIncidents();
    final fiveMinAgo = DateTime.now().subtract(const Duration(minutes: 5));
    final loc   = _location.text.trim().toLowerCase();
    final plant = _plant.toLowerCase();
    final title = (_aiBrief?['identified']?.toString() ?? _brief.text.split('.').first).trim().toLowerCase();
    final wsaCause = _wsaCause.toLowerCase();

    // Only flag as duplicate if same plant + location + similar title/cause within 5 min
    final found = existing.where((inc) {
      try {
        final incDate = DateTime.parse(inc['date']?.toString() ?? '');
        if (incDate.isBefore(fiveMinAgo)) return false;
      } catch (_) { return false; }
      final incLoc   = inc['location']?.toString().toLowerCase() ?? '';
      final incPlant = inc['plant']?.toString().toLowerCase()    ?? '';
      final incTitle = inc['title']?.toString().toLowerCase() ?? '';
      final incWsa   = inc['wsaCategory']?.toString().toLowerCase() ?? '';
      // Must match plant + location + (title OR WSA cause)
      return inc['type'] == 'NEAR_MISS' &&
             incPlant == plant &&
             incLoc == loc &&
             (incTitle == title || incWsa == wsaCause);
    }).toList();

    if (found.isNotEmpty) {
      if (!mounted) return true;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 22),
            SizedBox(width: 8),
            Text('Possible Duplicate', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
          content: const Text('A similar near miss (same location & category) was reported in the last 5 minutes.\n\nSubmit anyway?', style: TextStyle(fontSize: 13, height: 1.5)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD97706), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: const Text('Submit Anyway', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
          ]));
      return confirm != true;
    }
    return false;
  }

  /// ★ v31: Reset form for a new report
  void _resetForm() {
    setState(() {
      _saved = false;
      _pickedFile = null; _imageBytes = null; _aiBrief = null;
      _brief.clear(); _deptOther.clear(); _selectedDept = ''; _showOtherDept = false;
      _location.clear(); _description.clear(); _immediateAction.clear();
      for (final c in _additionalActions) { c.dispose(); }
      _additionalActions.clear();
      _aiSummary = null;
      _lastSubmissionKey = null;
    });
  }

  /// Save Report only — shows success dialog with share options (no PDF)
  void _handleSaveOnly() {
    _submittingAction = 'save';
    _submit(exportAfter: false);
  }

  /// ★ v25/v29/v30: Share Report — captures data + image BEFORE submit clears form
  void _handleShareReport() async {
    _submittingAction = 'share';
    // ★ v29 FIX: Build share text BEFORE _submit clears the form fields
    final shareText = '''🚨 NEAR MISS REPORT — ${_plant}
━━━━━━━━━━━━━━━━━━━━
📍 Location: ${_location.text.trim()}
🏭 Department: $_effectiveDept
⚠️ Category: $_wsaCause
🔴 Severity: $_severity
📋 Type: $_obsType

📝 Description:
${_description.text.trim()}

🔧 Corrective Actions:
${[_immediateAction.text.trim(), ..._additionalActions.map((c) => c.text.trim()).where((t) => t.isNotEmpty)].asMap().entries.map((e) => '${e.key + 1}. ${e.value}').join('\n')}

📅 Date: ${DateTime.now().toString().split('.').first}
👷 Reported via Safety Lens App''';

    // ★ v30: Save image to temp file BEFORE _submit clears _imageBytes
    XFile? shareImageFile;
    if (_imageBytes != null && !kIsWeb) {
      try {
        final tempDir = await getTemporaryDirectory();
        final imgFile = File('${tempDir.path}/near_miss_${DateTime.now().millisecondsSinceEpoch}.jpg');
        await imgFile.writeAsBytes(_imageBytes!);
        shareImageFile = XFile(imgFile.path, mimeType: 'image/jpeg');
      } catch (_) {
        // If temp file creation fails, share without image
      }
    }

    final success = await _submit(exportAfter: false);
    if (success && mounted) {
      try {
        if (shareImageFile != null) {
          // Share with image attached (works on WhatsApp, Telegram, etc.)
          await Share.shareXFiles(
            [shareImageFile],
            text: shareText,
            subject: 'Near Miss Report — $_plant',
          );
        } else {
          await Share.share(shareText, subject: 'Near Miss Report — $_plant');
        }
      } catch (_) {}
    }
  }

  /// Save + PDF — standalone, exports PDF after saving
  void _handleSavePdf() {
    _submittingAction = 'pdf';
    _submit(exportAfter: true);
  }

  Future<bool> _submit({bool exportAfter = false}) async {
    if (_submitting) return false; // Prevent double-tap
    final loc = _location.text.trim();
    if (loc.isEmpty || loc == 'To be confirmed (edit if needed)') {
      _snack('Please enter the actual location', AppColors.red);
      return false;
    }
    // ★ Validate description — must not be empty
    final desc = _description.text.trim();
    if (desc.isEmpty && _brief.text.trim().isEmpty) {
      _snack('Please describe the near miss incident', AppColors.red);
      return false;
    }
    // ★ v31: Validate corrective action — at least one must be filled
    final hasAction = _immediateAction.text.trim().isNotEmpty ||
        _additionalActions.any((c) => c.text.trim().isNotEmpty);
    if (!hasAction) {
      _snack('Please add at least one corrective action', AppColors.red);
      return false;
    }
    if (await _checkDuplicate()) return false;
    setState(() => _submitting = true);

    try {
      // Capture GPS location (non-blocking, best-effort)
      try {
        _capturedLocation = await GeoService.getCurrentLocation().timeout(
          const Duration(seconds: 8),
          onTimeout: () => LocationData(error: 'GPS timeout'),
        );
      } catch (_) {
        _capturedLocation = null;
      }

      final user = await LocalDB.getCurrentUser();
      final incident = <String, dynamic>{
        'id':              DateTime.now().millisecondsSinceEpoch.toString(),
        'title':           _aiBrief?['identified']?.toString().isNotEmpty == true
                               ? _aiBrief!['identified'].toString()
                               : _brief.text.trim().isNotEmpty
                                   ? _brief.text.split('.').first.trim()
                                   : _description.text.trim().split('.').first.trim(),
        'plant':           _plant,
        'dept':            _effectiveDept,
        'location':        loc,
        'severity':        _severity,
        'wsaCategory':     _wsaCause,
        'obsType':         _obsType,
        'desc':            '${_brief.text}\n\n${_description.text}'.trim(),
        'immediateAction': [
          _immediateAction.text.trim(),
          ..._additionalActions.map((c) => c.text.trim()).where((t) => t.isNotEmpty),
        ].join(' | '),
        'type':            'NEAR_MISS',
        'status':          'OPEN',
        'reportedBy':      user?['name'] ?? 'Unknown',
        'reportedByPno':   user?['pno']  ?? '',
        'date':            DateTime.now().toIso8601String(),
        // ★ v34: Compute risk score from severity so PDF report is never 0
        'riskScore':       _computeRiskScore(_severity),
        'confidence':      _aiBrief != null ? (_aiBrief!['confidence'] ?? 75) : 100,
        'overallRisk':     _severity,
        'imageBase64':     _imageBytes != null ? base64Encode(_imageBytes!) : null,
        'thumbnailBase64': _imageBytes != null ? _generateThumbnail(_imageBytes!) : null,
        'shareImageBase64': _imageBytes != null ? _generateShareImage(_imageBytes!) : null,
      };

      // Add GPS data if available
      if (_capturedLocation != null && _capturedLocation!.isValid) {
        incident['latitude'] = _capturedLocation!.latitude;
        incident['longitude'] = _capturedLocation!.longitude;
        incident['locationAccuracy'] = _capturedLocation!.accuracy;
        incident['locationAddress'] = _capturedLocation!.address;
        incident['locationTimestamp'] = _capturedLocation!.timestamp.toIso8601String();
      }

      await LocalDB.saveIncident(incident);

      // ★ AI correction feedback loop: if the AI populated the form and the user
      // then changed the summary, corrective action, or severity, record each
      // edit so an admin can decide whether the AI was wrong (→ training data)
      // or the user just preferred different wording. Fire-and-forget.
      if (_aiOriginalSuggestion != null) {
        final incId = incident['id']?.toString() ?? '';
        final editedBy = (user?['name'] ?? user?['username'] ?? '').toString();
        AiCorrectionService.recordSingleEdit(
          incidentId: incId, incidentType: 'NEAR_MISS',
          field: AiCorrectionService.fieldSummary,
          original: _aiOriginalSuggestion!['summary'] ?? '',
          edited: _description.text.trim(),
          plant: _plant, editedBy: editedBy,
          aiSource: _aiOriginalSource ?? '',
        ).catchError((_) {});
        AiCorrectionService.recordSingleEdit(
          incidentId: incId, incidentType: 'NEAR_MISS',
          field: AiCorrectionService.fieldCorrectiveAction,
          original: _aiOriginalSuggestion!['correctiveAction'] ?? '',
          edited: _immediateAction.text.trim(),
          plant: _plant, editedBy: editedBy,
          aiSource: _aiOriginalSource ?? '',
        ).catchError((_) {});
        AiCorrectionService.recordSingleEdit(
          incidentId: incId, incidentType: 'NEAR_MISS',
          field: AiCorrectionService.fieldOverallRisk,
          original: _aiOriginalSuggestion!['severity'] ?? '',
          edited: _severity,
          plant: _plant, editedBy: editedBy,
          aiSource: _aiOriginalSource ?? '',
        ).catchError((_) {});
      }

      // Start network sync but don't block — show success after max 5s
      final syncFuture = SyncService.pushIncident(incident).catchError((_) => false);
      // Only generate/upload PDF in background if user chose Save+PDF
      if (exportAfter) _uploadPdfBackground(incident, user, _imageBytes);
      _lastSubmissionKey = _buildSubmissionKey();
      final synced = await syncFuture.timeout(
        const Duration(seconds: 5), onTimeout: () => false);

      if (exportAfter) {
        try {
          await PdfExport.downloadOrShareIncident(
            incident:    incident,
            reporterName: user?['name']?.toString() ?? 'SAIL Safety Officer',
            reporterPno:  user?['pno']?.toString()  ?? '',
            imageBytes:  _imageBytes,
          );
        } catch (e) {
          if (mounted) _snack('PDF export failed: $e', AppColors.red);
        }
      }

      // ★ v30/v31 FIX: Preserve image bytes for share dialog
      final preservedImageBytes = _imageBytes != null ? Uint8List.fromList(_imageBytes!) : null;

      if (mounted) {
        setState(() {
          _submitting = false;
          _submittingAction = null;
          _saved = true; // ★ v31: Mark as saved — form content remains visible
        });
        _showSaveSuccessDialog(incident, synced, exportAfter, preservedImageBytes);
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() { _submitting = false; _submittingAction = null; });
        _snack('Save failed: $e', AppColors.red);
      }
      return false;
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        Icon(
          color == AppColors.green ? Icons.check_circle_rounded
            : color == AppColors.red ? Icons.error_rounded
            : Icons.info_rounded,
          color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(msg, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
      ]),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 3),
    ));
  }

  // ═══════════════════════════════════════════════════════════════
  //  SHARE HELPERS
  // ═══════════════════════════════════════════════════════════════

  void _showSaveSuccessDialog(Map<String, dynamic> incident, bool synced, bool exported, [Uint8List? savedImageBytes]) {
    final sl = SL.of(context);
    showDialog(context: context, builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: (exported ? AppColors.accent : AppColors.green).withOpacity(0.1),
              shape: BoxShape.circle),
            child: Icon(
              exported ? Icons.picture_as_pdf_rounded : Icons.check_circle_rounded,
              color: exported ? sl.accentText : sl.greenText, size: 48)),
          const SizedBox(height: 16),
          Text(exported ? 'Saved + PDF Exported' : 'Near Miss Saved!',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(synced ? 'Synced to cloud ☁️' : 'Saved locally (will sync later)',
            style: TextStyle(fontSize: 13, color: sl.text3)),
          const SizedBox(height: 20),
          // Share buttons — always show for Save, show for PDF too
          Text('Share Report', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sl.text3)),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _shareBtn(iconWidget: _whatsAppIcon(20), label: 'WhatsApp',
              color: const Color(0xFF25D366),
              onTap: () { Navigator.pop(ctx); _shareViaWhatsApp(incident, savedImageBytes); }),
            _shareBtn(icon: Icons.email_outlined, label: 'Email',
              color: const Color(0xFF1976D2),
              onTap: () { Navigator.pop(ctx); _shareViaEmail(incident, savedImageBytes); }),
            _shareBtn(icon: Icons.share_rounded, label: 'More',
              color: AppColors.accent,
              onTap: () { Navigator.pop(ctx); _shareGeneric(incident, savedImageBytes); }),
          ]),
          const SizedBox(height: 16),
          TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w600))),
        ],
      )),
    ));
  }

  Widget _shareBtn({IconData? icon, Widget? iconWidget, required String label,
      required Color color, required VoidCallback onTap}) {
    final sl = SL.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.4))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          iconWidget ?? Icon(icon, color: sl.textOn(color), size: 20),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: sl.textOn(color), fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Widget _whatsAppIcon(double size) {
    return Container(
      width: size, height: size,
      decoration: const BoxDecoration(
        color: Color(0xFF25D366),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.phone, color: Colors.white, size: size * 0.6),
    );
  }

  String _buildShareText(Map<String, dynamic> incident) {
    final title    = incident['title']?.toString() ?? 'Near Miss Report';
    final severity = incident['severity']?.toString() ?? 'MEDIUM';
    final plant    = incident['plant']?.toString() ?? '';
    final dept     = incident['dept']?.toString() ?? '';
    final location = incident['location']?.toString() ?? '';
    final desc     = incident['desc']?.toString() ?? '';
    final date     = incident['date']?.toString().split('T').first ?? '';
    final action   = incident['immediateAction']?.toString() ?? '';
    final category = incident['wsaCategory']?.toString() ?? '';

    final buf = StringBuffer();
    buf.writeln('⚠️ *SAIL Safety Lens — Near Miss Report*');
    buf.writeln();
    buf.writeln('📋 *Title:* $title');
    buf.writeln('🔴 *Severity:* $severity');
    buf.writeln('🏭 *Plant:* $plant');
    if (dept.isNotEmpty) buf.writeln('🏢 *Department:* $dept');
    buf.writeln('📍 *Location:* $location');
    buf.writeln('📅 *Date:* $date');
    if (category.isNotEmpty) buf.writeln('⚠️ *Category:* $category');
    buf.writeln();
    if (desc.isNotEmpty) {
      buf.writeln('📝 *Description:*');
      buf.writeln(desc);
      buf.writeln();
    }
    if (action.isNotEmpty) {
      buf.writeln('🔧 *Corrective Action:*');
      buf.writeln(action);
      buf.writeln();
    }
    buf.writeln('—');
    buf.write('_Generated by SAIL Safety Lens_');
    return buf.toString();
  }

  Future<void> _shareViaWhatsApp(Map<String, dynamic> incident, [Uint8List? savedImageBytes]) async {
    // ★ v32: Always use Share.shareXFiles / Share.share — never use wa.me URLs
    // wa.me opens a new browser tab every time; native share intent reuses existing WhatsApp
    try {
      final text = _buildShareText(incident);

      if (!kIsWeb && savedImageBytes != null) {
        // Share image file with text caption — WhatsApp shows image inline
        final tempDir = await getTemporaryDirectory();
        final imgFile = File('${tempDir.path}/near_miss_${incident['id']}.jpg');
        await imgFile.writeAsBytes(savedImageBytes);
        await Share.shareXFiles(
          [XFile(imgFile.path, mimeType: 'image/jpeg')],
          text: text,
          subject: 'Near Miss Report — ${incident['plant'] ?? ''}',
        );
      } else {
        // No image — use native share (opens share sheet, user picks WhatsApp)
        await Share.share(text, subject: 'Near Miss Report — ${incident['plant'] ?? ''}');
      }
    } catch (e) {
      final text = _buildShareText(incident);
      await Share.share(text);
    }
  }

  Future<void> _shareViaEmail(Map<String, dynamic> incident, [Uint8List? savedImageBytes]) async {
    final text    = _buildShareText(incident);
    final title   = incident['title']?.toString() ?? 'Near Miss Report';
    final subject = 'SAIL Safety Lens: $title';

    // ★ v30: Try to share with PDF + image attachment via shareXFiles
    if (!kIsWeb && savedImageBytes != null) {
      try {
        final tempDir = await getTemporaryDirectory();
        final user = await LocalDB.getCurrentUser();
        final pdfBytes = await PdfExport.generateIncidentReportBytes(
          incident: incident,
          reporterName: user?['name']?.toString() ?? 'SAIL Safety Officer',
          reporterPno: user?['pno']?.toString() ?? '',
          imageBytes: savedImageBytes,
        );
        if (pdfBytes.isNotEmpty) {
          final pdfFile = File('${tempDir.path}/SafetyLens_${incident['id']}.pdf');
          await pdfFile.writeAsBytes(pdfBytes);
          await Share.shareXFiles(
            [XFile(pdfFile.path, mimeType: 'application/pdf')],
            text: text,
            subject: subject,
          );
          return;
        }
      } catch (_) {}
    }

    // Fallback: mailto or plain text share
    final url = Uri(scheme: 'mailto', query: 'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(text)}');
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else {
        await Share.share(text, subject: subject);
      }
    } catch (_) {
      await Share.share(text, subject: subject);
    }
  }

  Future<void> _shareGeneric(Map<String, dynamic> incident, [Uint8List? savedImageBytes]) async {
    final text = _buildShareText(incident);

    // ★ v30: Share with image file if available
    if (!kIsWeb && savedImageBytes != null) {
      try {
        final tempDir = await getTemporaryDirectory();
        final imgFile = File('${tempDir.path}/near_miss_photo_${incident['id']}.jpg');
        await imgFile.writeAsBytes(savedImageBytes);
        await Share.shareXFiles(
          [XFile(imgFile.path, mimeType: 'image/jpeg')],
          text: text,
          subject: 'Near Miss Report — ${incident['plant'] ?? ''}',
        );
        return;
      } catch (_) {}
    }
    await Share.share(text);
  }

  // ═══════════════════════════════════════════════════════════════
  //  LISTENING BANNER — shows at top when voice is active
  // ═══════════════════════════════════════════════════════════════
  Widget _listeningBanner(SL sl) {
    if (!_isListening) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _micPulse,
      builder: (_, __) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.red.withOpacity(0.12), Colors.red.withOpacity(0.05)]),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.withOpacity(0.4))),
        child: Row(children: [
          Transform.scale(
            scale: _micPulse.value,
            child: Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                shape: BoxShape.circle),
              child: const Icon(Icons.mic, color: Colors.red, size: 16)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Listening...', style: TextStyle(color: Colors.red.shade700, fontSize: 12, fontWeight: FontWeight.w700)),
              Text('Speak in any language. Auto-stops after 5s pause → AI frames it.',
                style: TextStyle(color: sl.text3, fontSize: 10)),
            ])),
          GestureDetector(
            onTap: () => _toggleVoice(_activeMicField),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
              child: Text('STOP', style: TextStyle(
                color: Colors.red.shade700, fontSize: 10, fontWeight: FontWeight.w800))),
          ),
        ]),
      ),
    );
  }

  Widget _stepLabel(String num, String txt, SL sl) => Row(children: [
    Container(
      width: 22, height: 22,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF4F5BD5), Color(0xFF0EA5B5)]),
        borderRadius: BorderRadius.circular(7)),
      child: Center(child: Text(num, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)))),
    const SizedBox(width: 8),
    Text(txt, style: TextStyle(color: sl.text1, fontSize: 13, fontWeight: FontWeight.w700))
  ]);

  Widget _submitBtn({required String label, required String actionId, required IconData icon, required List<Color> colors, required VoidCallback onTap}) {
    final isThisLoading = _submitting && _submittingAction == actionId;
    return AbsorbPointer(
      absorbing: _submitting,
      child: Opacity(
        opacity: _submitting && !isThisLoading ? 0.5 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(color: colors.first.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3)),
            ]),
          child: ElevatedButton.icon(
            onPressed: onTap,
            icon: isThisLoading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(icon, size: 16, color: Colors.white),
            label: Text(isThisLoading ? 'Saving...' : label, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
        ),
      ),
    );
  }

  Widget _guidanceBox(SL sl) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: [AppColors.amber.withOpacity(0.08), AppColors.amber.withOpacity(0.03)]),
      border: Border.all(color: AppColors.amber.withOpacity(0.4)),
      borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.amber.withOpacity(0.15),
            borderRadius: BorderRadius.circular(6)),
          child: Icon(Icons.lightbulb_outline_rounded, size: 14, color: sl.amberText)),
        const SizedBox(width: 8),
        Text('Reporting Guidance', style: TextStyle(color: sl.amberText, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      Text(
        'A near miss is an unplanned event that did NOT result in injury but had the potential to do so. Report freely — no blame, only learning.',
        style: TextStyle(color: sl.text2, fontSize: 11, height: 1.5)),
    ]));

  Widget _imageSection(SL sl) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(sl.isDark ? 0.2 : 0.06), blurRadius: 12, offset: const Offset(0, 3)),
        ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _stepLabel('1', 'Image Evidence (Optional)', sl),
        const SizedBox(height: 12),
        if (_imageBytes == null && !_analyzing) _emptyImage(sl),
        if (_analyzing) _analyzingImage(),
        if (_imageBytes != null && !_analyzing && _aiBrief != null) _imageWithBrief(sl),
        if (_imageBytes != null && !_analyzing && _aiBrief == null) _imageAttachedOnly(sl),
      ]));
  }

  /// Shows image with correct aspect ratio when user chose "Just Attach" (no AI scan)
  Widget _imageAttachedOnly(SL sl) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            _imageBytes!,
            width: double.infinity,
            fit: BoxFit.contain, // ★ Preserves full aspect ratio — no cropping
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.green.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.check_circle, size: 13, color: sl.greenText),
            const SizedBox(width: 6),
            Text('Image attached', style: TextStyle(color: sl.text2, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        )),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () => setState(() { _pickedFile = null; _imageBytes = null; }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.red.withOpacity(0.5)),
              borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 13, color: sl.redText),
              const SizedBox(width: 4),
              Text('Remove', style: TextStyle(color: sl.redText, fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ]),
    ],
  );

  Widget _emptyImage(SL sl) => Column(children: [
    GestureDetector(
      onTap: () => _pickImage(ImageSource.camera),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [AppColors.accent.withOpacity(0.06), AppColors.accent.withOpacity(0.02)]),
          border: Border.all(color: AppColors.accent.withOpacity(0.3), width: 1.5),
          borderRadius: BorderRadius.circular(14)),
        child: Column(children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [AppColors.accent.withOpacity(0.15), AppColors.accent.withOpacity(0.05)]),
              shape: BoxShape.circle),
            child: Icon(Icons.camera_alt_rounded, size: 28, color: sl.accentText)),
          const SizedBox(height: 12),
          Text('Tap to capture hazard photo', style: TextStyle(color: sl.text1, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('AI will auto-identify hazard & pre-fill the form', style: TextStyle(color: sl.text4, fontSize: 10)),
        ])),
    ),
    const SizedBox(height: 10),
    Row(children: [
      Expanded(child: _actionButton(
        icon: Icons.camera_alt_rounded,
        label: 'Capture',
        filled: true,
        onTap: () => _pickImage(ImageSource.camera),
      )),
      const SizedBox(width: 10),
      Expanded(child: _actionButton(
        icon: Icons.photo_library_rounded,
        label: 'Gallery',
        filled: false,
        onTap: () => _pickImage(ImageSource.gallery),
      )),
    ]),
  ]);

  Widget _actionButton({required IconData icon, required String label, required bool filled, required VoidCallback onTap}) {
    final sl = SL.of(context);
    if (filled) {
      return Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF4F5BD5), Color(0xFF0EA5B5)]),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: AppColors.accent.withOpacity(0.25), blurRadius: 6, offset: const Offset(0, 2))]),
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 15, color: Colors.white),
          label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent, shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15, color: sl.accentText),
      label: Text(label, style: TextStyle(color: sl.accentText, fontSize: 12, fontWeight: FontWeight.w600)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: AppColors.accent, width: 1.5),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );
  }

  Widget _analyzingImage() {
    final sl = SL.of(context);
    return Container(
    // 140 → 190 to fit the progress bar, its phase caption and the elapsed
    // counter. "Please wait..." is gone: it was the least informative line on
    // the screen and the space is better spent saying what is happening and how
    // long it has been.
    height: 190,
    decoration: BoxDecoration(
      color: sl.card2,
      borderRadius: BorderRadius.circular(12),
      image: _imageBytes != null ? DecorationImage(image: MemoryImage(_imageBytes!), fit: BoxFit.cover) : null),
    child: Container(
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(12)),
      child: Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.accent)),
          const SizedBox(height: 10),
          Text(_step.isEmpty ? 'Analysing the photo' : _step,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const AnalysisProgress(accent: AppColors.accent, compact: true),
        ]))));
  }

  /// Plain-language reason this photo was not analysed.
  ///
  /// Falls back to the old connectivity wording only when GeminiVision supplied
  /// no reason, because "retry when connected" is actively misleading when the
  /// device IS connected and the real cause is the account's spent daily AI
  /// allowance — the user goes hunting for a signal problem that isn't there.
  String _offlineExplanation() {
    final reason = _aiBrief?['offlineReason']?.toString() ?? '';
    final hint   = _aiBrief?['offlineHint']?.toString() ?? '';
    if (reason.isEmpty && hint.isEmpty) {
      return 'AI could not analyze image. Fill the form manually or retry when '
          'connected.';
    }
    final parts = <String>[];
    if (reason.isNotEmpty) {
      // Spliced after "because", so the fragment must be lower-case.
      parts.add('Not analysed because '
          '${reason[0].toLowerCase()}${reason.substring(1)}.');
    } else {
      parts.add('This photo was not analysed.');
    }
    // Every hint already ends by telling the reporter they can fill the form in
    // by hand, so appending it again reads as a stutter. Only add it when there
    // is no hint to carry the message.
    if (hint.isNotEmpty) {
      parts.add(hint);
    } else {
      parts.add('You can fill the form manually.');
    }
    return parts.join(' ');
  }

  /// The banner icon has to agree with the banner text: a spent quota or a
  /// rejected key shown next to a wifi-off symbol tells the reporter to go find
  /// a signal, which is the wrong action and wastes their time.
  IconData _offlineIcon() {
    final r = (_aiBrief?['offlineReason']?.toString() ?? '').toLowerCase();
    if (r.contains('internet') || r.contains('offline')) {
      return Icons.wifi_off_rounded;
    }
    if (r.contains('limit') || r.contains('allowance') || r.contains('used up')) {
      return Icons.cloud_off_rounded;
    }
    if (r.contains('key')) return Icons.vpn_key_off_rounded;
    if (r.contains('minute') || r.contains('still running')) {
      return Icons.hourglass_bottom_rounded;
    }
    return Icons.info_outline_rounded;
  }

  Widget _imageWithBrief(SL sl) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 250),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_imageBytes!, fit: BoxFit.contain, width: double.infinity),
        ),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _isOnlineMode
              ? [AppColors.accent.withOpacity(0.08), AppColors.accent.withOpacity(0.02)]
              : [AppColors.amber.withOpacity(0.08), AppColors.amber.withOpacity(0.02)]),
          border: Border.all(color: _isOnlineMode ? AppColors.accent.withOpacity(0.3) : AppColors.amber.withOpacity(0.3), width: 1.5),
          borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome, size: 14, color: _isOnlineMode ? sl.accentText : sl.amberText),
            const SizedBox(width: 6),
            Text(_isOnlineMode ? 'AI Assessment' : 'AI Unavailable — Manual Entry',
              style: TextStyle(color: _isOnlineMode ? sl.accentText : sl.amberText, fontSize: 12, fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.12),
                border: Border.all(color: AppColors.amber.withOpacity(0.6)),
                borderRadius: BorderRadius.circular(8)),
              child: Text('${_aiBrief!['severity']} · ${_aiBrief!['confidence']}%',
                style: TextStyle(color: sl.amberText, fontSize: 11, fontWeight: FontWeight.w800))),  // Improved: was 9px
          ]),
          if (!_isOnlineMode) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(_offlineIcon(), color: sl.amberText, size: 14),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  _offlineExplanation(),
                  style: TextStyle(color: sl.amberText, fontSize: 10, height: 1.3))),
              ]),
            ),
          ],
          const SizedBox(height: 10),
          _briefRow('Identified', _aiBrief!['identified'].toString(), sl),
          _briefRow('Statutory',  _aiBrief!['statutory'].toString(),  sl),
          _briefRow('Type',       _aiBrief!['type'].toString(),       sl),
          const SizedBox(height: 10),
          Text('AI brief (editable):', style: TextStyle(color: sl.text3, fontSize: 10, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: _brief,
            maxLines: 4,
            style: TextStyle(color: sl.text1, fontSize: 12, height: 1.5),
            decoration: InputDecoration(
              filled: true,
              fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
              contentPadding: const EdgeInsets.all(12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: sl.border)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.accent, width: 2)),
            )),
          const SizedBox(height: 6),
          Text('Edit any field above or in the form below', textAlign: TextAlign.center, style: TextStyle(color: sl.text4, fontSize: 10)),
        ])),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: () => setState(() { _pickedFile = null; _imageBytes = null; _aiBrief = null; _brief.clear(); }),
        icon: Icon(Icons.delete_outline_rounded, size: 15, color: sl.redText),
        label: Text('Remove Image', style: TextStyle(color: sl.redText, fontSize: 12, fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: AppColors.red.withOpacity(0.5), width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 11),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    ]);

  Widget _briefRow(String k, String v, SL sl) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 80, child: Text(k, style: TextStyle(color: sl.text4, fontSize: 10, fontWeight: FontWeight.w700))),
      Expanded(child: Text(v, style: TextStyle(color: sl.text1, fontSize: 11, height: 1.4))),
    ]));

  // ═══════════════════════════════════════════════════════════════
  //  DETAILS FORM SECTION — with voice mic buttons
  // ═══════════════════════════════════════════════════════════════
  Widget _detailsSection(SL sl) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(sl.isDark ? 0.2 : 0.06), blurRadius: 12, offset: const Offset(0, 3)),
        ]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepLabel('2', 'Observation Particulars', sl),
          const SizedBox(height: 14),
          _buildDropdownField('Plant/Unit', _plant, _plants, (v) => setState(() => _plant = v!), sl),
          _buildDeptDropdown(sl),
          if (_showOtherDept)
            _buildTextField('Enter Department Name', _deptOther, Icons.edit_outlined, sl),
          _buildLocationField(sl),
          _buildDropdownField('Observation Category (WSA 13)', _wsaCause, _wsaCauses, (v) => setState(() => _wsaCause = v!), sl),
          _buildDropdownField('Observation Type', _obsType, _obsTypes, (v) => setState(() => _obsType = v!), sl),
          _buildDropdownField('Initial Risk Severity', _severity, _severities, (v) => setState(() => _severity = v!), sl),
          // ★ Reference image now shown in _imageSection at top (via _imageAttachedOnly)
          // ★ AI Summary of Near Miss (shown after AI processes voice/text input)
          if (_aiSummary != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.accent.withOpacity(0.06), AppColors.accent.withOpacity(0.02)]),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.accent.withOpacity(0.3))),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.summarize_rounded, size: 13, color: sl.accentText),
                      const SizedBox(width: 6),
                      Text('Summary of Near Miss',
                        style: TextStyle(color: sl.accentText, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _aiSummary = null),
                        child: Icon(Icons.close, size: 13, color: sl.text4)),
                    ]),
                    const SizedBox(height: 6),
                    Text(_aiSummary!,
                      style: TextStyle(color: sl.text1, fontSize: 11.5, height: 1.4, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          // ★ v25: Voice language selector chips
          _buildVoiceLangChips(sl),
          // Names the box the mic feeds. The field's own placeholder only talks
          // about the mic, which made voice look like the ONLY way in; a worker
          // who would rather type needs to be told that is equally fine. Sits
          // below the language chips because it covers both input routes.
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text('Describe Near Miss either by typing or by voice',
              style: TextStyle(
                color: sl.text2, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          _buildTextField('Tap mic → speak in ${_selectedVoiceLang == "hi" ? "Hindi" : "English"} → AI frames it', _description, Icons.description_outlined, sl, maxLines: 3,
            suffix: _micButton(_description), onChanged: _onDescriptionChanged),
          // ★ AI Suggestion Card
          if (_aiRefining)
            _buildAiRefiningIndicator(sl),
          if (_aiSuggestion != null)
            _buildAiSuggestionCard(sl),
          _buildTextField('Corrective Action 1', _immediateAction, Icons.flash_on_outlined, sl, maxLines: 2,
            suffix: _micButton(_immediateAction)),
          // ★ Additional corrective actions
          ..._additionalActions.asMap().entries.map((entry) {
            final idx = entry.key;
            final ctrl = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildTextField(
                      'Corrective Action ${idx + 2}', ctrl, Icons.flash_on_outlined, sl, maxLines: 2),
                  ),
                  GestureDetector(
                    onTap: () => setState(() {
                      _additionalActions[idx].dispose();
                      _additionalActions.removeAt(idx);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 14, left: 4),
                      child: Icon(Icons.remove_circle_outline, size: 20, color: sl.redText.withOpacity(0.7)),
                    ),
                  ),
                ],
              ),
            );
          }),
          // ★ Add more corrective actions button
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: GestureDetector(
              onTap: () => setState(() => _additionalActions.add(TextEditingController())),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.accent.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(8),
                  color: AppColors.accent.withOpacity(0.04)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.add_circle_outline, size: 15, color: sl.accentText),
                  const SizedBox(width: 6),
                  Text('Add Corrective Action',
                    style: TextStyle(color: sl.accentText, fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ★ v25: Animated mic button — tap to start, long-press to pick language
  Widget _micButton(TextEditingController field) {
    final sl = SL.of(context);
    final isActive = _isListening && _activeMicField == field;
    return AnimatedBuilder(
      animation: _micPulse,
      builder: (_, __) => GestureDetector(
        onTap: () => _toggleVoice(field),
        onLongPress: () => _showVoiceLangPicker(),
        child: Container(
          width: 36, height: 36,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(
            color: isActive ? Colors.red.withOpacity(0.12) : AppColors.accent.withOpacity(0.08),
            shape: BoxShape.circle,
            border: Border.all(
              color: isActive ? Colors.red.withOpacity(0.5) : Colors.transparent,
              width: 1.5)),
          child: Transform.scale(
            scale: isActive ? _micPulse.value * 0.85 : 1.0,
            child: Icon(
              isActive ? Icons.mic : Icons.mic_none_rounded,
              color: isActive ? Colors.red : sl.accentText,
              size: 18)),
        ),
      ),
    );
  }

  /// ★ v25: Language picker popup for voice input
  void _showVoiceLangPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Select Voice Language', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Speak in this language — text will appear in native script',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 16),
          _langOption('hi', 'हिन्दी (Hindi)', '🇮🇳'),
          _langOption('en', 'English', '🇬🇧'),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  /// ★ v25: Inline language selector chips above description field
  Widget _buildVoiceLangChips(SL sl) {
    const langs = [
      {'code': 'hi', 'label': 'हिन्दी', 'short': 'Hindi'},
      {'code': 'en', 'label': 'English', 'short': 'EN'},
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Icon(Icons.translate_rounded, size: 14, color: sl.text3),
        const SizedBox(width: 6),
        Text('Voice:', style: TextStyle(color: sl.text3, fontSize: 10, fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        ...langs.map((l) {
          final isSelected = _selectedVoiceLang == l['code'];
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => setState(() {
                _selectedVoiceLang = l['code']!;
                _detectedLang = l['code']!; // AI replies in the chosen language
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.accent.withOpacity(0.15) : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isSelected ? AppColors.accent : sl.border.withOpacity(0.4),
                    width: isSelected ? 1.5 : 1),
                ),
                child: Text(l['label']!,
                  style: TextStyle(
                    color: isSelected ? sl.accentText : sl.text3,
                    fontSize: 10,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400)),
              ),
            ),
          );
        }),
      ]),
    );
  }

  Widget _langOption(String code, String label, String flag) {
    final sl = SL.of(context);
    final isSelected = _selectedVoiceLang == code;
    return ListTile(
      leading: Text(flag, style: const TextStyle(fontSize: 22)),
      title: Text(label, style: TextStyle(
        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
        color: isSelected ? sl.accentText : null)),
      trailing: isSelected ? Icon(Icons.check_circle, color: sl.accentText, size: 20) : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      tileColor: isSelected ? AppColors.accent.withOpacity(0.08) : null,
      onTap: () {
        setState(() {
          _selectedVoiceLang = code;
          _detectedLang = code; // AI replies in the chosen language
        });
        Navigator.pop(context);
        _snack('Voice language: $label — speak and text will appear in native script', AppColors.accent);
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v24: AI REFINEMENT UI WIDGETS
  // ═══════════════════════════════════════════════════════════════
  Widget _buildAiRefiningIndicator(SL sl) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent)),
          const SizedBox(width: 10),
          Text('AI is analyzing your description...',
            style: TextStyle(color: sl.text3, fontSize: 11, fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }

  Widget _buildAiSuggestionCard(SL sl) {
    final isNearMiss = _aiSuggestion!['isNearMiss'] == true;
    final confidence = (_aiSuggestion!['confidence'] ?? 0) as num;
    final reason = _aiSuggestion!['reason']?.toString() ?? '';
    final refined = _aiSuggestion!['refined']?.toString() ?? '';
    final correctiveAction = _aiSuggestion!['correctiveAction']?.toString() ?? '';
    final detectedLang = _aiSuggestion!['detectedLanguage']?.toString() ?? '';

    final cardColor = isNearMiss
        ? (sl.isDark ? const Color(0xFF1B3A2E) : const Color(0xFFE8F5E9))
        : (sl.isDark ? const Color(0xFF3A1B1B) : const Color(0xFFFFEBEE));
    final borderColor = isNearMiss
        ? const Color(0xFF43A047)
        : const Color(0xFFD32F2F);
    final iconData = isNearMiss ? Icons.check_circle_outline : Icons.error_outline_rounded;
    final iconColor = isNearMiss ? const Color(0xFF43A047) : const Color(0xFFD32F2F);

    // ★ v25: Confidence color coding
    Color confidenceColor;
    if (confidence >= 80) confidenceColor = const Color(0xFF43A047);
    else if (confidence >= 50) confidenceColor = const Color(0xFFF57C00);
    else confidenceColor = const Color(0xFFD32F2F);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor.withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ★ v25: Status header with prominent confidence badge
            Row(
              children: [
                Icon(iconData, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isNearMiss ? 'Valid Near Miss' : 'Does NOT Qualify as Near Miss',
                    style: TextStyle(
                      color: iconColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800)),
                ),
                // ★ Confidence badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: confidenceColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: confidenceColor.withOpacity(0.5)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.psychology_rounded, size: 12, color: confidenceColor),
                    const SizedBox(width: 4),
                    Text('${confidence.toInt()}%',
                      style: TextStyle(color: confidenceColor, fontSize: 12, fontWeight: FontWeight.w900)),
                  ]),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _dismissAiSuggestion,
                  child: Icon(Icons.close, size: 16, color: sl.text4),
                ),
              ],
            ),
            // ★ v25: Confidence level explanation
            const SizedBox(height: 6),
            Text(
              'AI Confidence: ${confidence.toInt()}% — ${confidence >= 80 ? "High confidence" : confidence >= 50 ? "Moderate confidence" : "Low confidence"}${detectedLang.isNotEmpty ? ' • Language: $detectedLang' : ''}',
              style: TextStyle(color: sl.text4, fontSize: 10, fontWeight: FontWeight.w500)),
            // ★ v25: Prominent rejection message for non-near-miss
            if (!isNearMiss) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFD32F2F).withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFD32F2F).withOpacity(0.3)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFFD32F2F)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    reason.isNotEmpty ? reason : 'The description provided does not match the definition of a near miss. A near miss is an unplanned event that did NOT result in injury but had the potential to cause harm.',
                    style: TextStyle(color: sl.isDark ? Colors.red.shade200 : Colors.red.shade800, fontSize: 11.5, height: 1.4, fontWeight: FontWeight.w500))),
                ]),
              ),
            ],
            if (isNearMiss && reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(reason,
                style: TextStyle(color: sl.text2, fontSize: 11, height: 1.3)),
            ],
            if (refined.isNotEmpty && isNearMiss) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: sl.isDark ? Colors.black26 : Colors.white.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI Refined Description:',
                      style: TextStyle(color: sl.text3, fontSize: 10, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(refined,
                      style: TextStyle(color: sl.text1, fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
            ],
            // ★ v35: Show AI-suggested corrective action
            if (correctiveAction.isNotEmpty && isNearMiss) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: sl.isDark ? const Color(0xFF1A2A1A) : const Color(0xFFF1F8E9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF43A047).withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.build_circle_outlined, size: 13, color: const Color(0xFF43A047)),
                      const SizedBox(width: 6),
                      Text('Suggested Corrective Action:',
                        style: TextStyle(color: const Color(0xFF43A047), fontSize: 10, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 4),
                    Text(correctiveAction,
                      style: TextStyle(color: sl.text1, fontSize: 12, height: 1.4)),
                    const SizedBox(height: 4),
                    Text('You can edit this after accepting',
                      style: TextStyle(color: sl.text3, fontSize: 11, fontStyle: FontStyle.italic)),  // Improved: was text4/9px
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (refined.isNotEmpty && isNearMiss)
                  Expanded(
                    child: GestureDetector(
                      onTap: _acceptAiRefinement,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Center(
                          child: Text('Use AI Version',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  ),
                if (refined.isNotEmpty && isNearMiss) const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    onTap: _dismissAiSuggestion,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: sl.text4.withOpacity(0.5)),
                      ),
                      child: Center(
                        child: Text(isNearMiss ? 'Keep My Text' : 'Try Again',
                          style: TextStyle(color: sl.text2, fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// ★ v32: Location field with GPS indicator + edit hint
  Widget _buildLocationField(SL sl) {
    final hasGpsLocation = _capturedLocation != null && _capturedLocation!.isValid;
    final isAutoFilled = hasGpsLocation &&
        _location.text.isNotEmpty &&
        _location.text != 'To be confirmed (edit if needed)';

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _location,
          onChanged: _onLocationChanged,
          style: TextStyle(color: sl.text1, fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Exact Location',
            labelStyle: TextStyle(color: sl.text3, fontSize: 11.5),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Icon(Icons.location_on_outlined, size: 18,
                color: isAutoFilled ? sl.greenText : sl.accentText.withOpacity(0.7))),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              if (isAutoFilled)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.gps_fixed_rounded, size: 14,
                    color: sl.greenText.withOpacity(0.7))),
              _micButton(_location),
            ]),
            filled: true,
            fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isAutoFilled ? AppColors.green.withOpacity(0.4) : sl.border.withOpacity(0.5))),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.accent, width: 2)),
          ),
        ),
        if (isAutoFilled)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 4),
            child: Text(
              '📍 Auto-detected from ${_location.text.contains(',') && _capturedLocation?.address == null ? "image EXIF" : "GPS"} — tap to edit if incorrect',
              style: TextStyle(color: sl.greenText.withOpacity(0.8), fontSize: 10, fontStyle: FontStyle.italic),
            ),
          ),
      ]),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, IconData icon, SL sl, {int maxLines = 1, TextInputType keyboardType = TextInputType.text, Widget? suffix, void Function(String)? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: TextStyle(color: sl.text1, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: sl.text3, fontSize: 11.5),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 12, right: 8),
            child: Icon(icon, size: 18, color: sl.accentText.withOpacity(0.7))),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: suffix,
          filled: true,
          fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.accent, width: 2)),
        ),
      ),
    );
  }

  /// Department dropdown with "Other" option
  Widget _buildDeptDropdown(SL sl) {
    // Build items list: departments from admin + "Other" at end
    final items = [..._departments, 'Other'];
    final currentValue = _showOtherDept
        ? 'Other'
        : (items.contains(_selectedDept) ? _selectedDept : '');

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<String>(
        value: currentValue.isEmpty ? null : currentValue,
        hint: Text('Department/Shop', style: TextStyle(color: sl.text3, fontSize: 11.5)),
        items: items.map((e) => DropdownMenuItem(
          value: e,
          child: Text(
            e,
            style: TextStyle(
              fontSize: 12,
              fontStyle: e == 'Other' ? FontStyle.italic : FontStyle.normal,
              color: e == 'Other' ? sl.accentText : sl.text1,
            ),
          ),
        )).toList(),
        onChanged: (v) {
          setState(() {
            if (v == 'Other') {
              _selectedDept = 'Other';
              _showOtherDept = true;
            } else {
              _selectedDept = v ?? '';
              _showOtherDept = false;
              _deptOther.clear();
            }
          });
        },
        dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
        style: TextStyle(color: sl.text1, fontSize: 12),
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: sl.text3),
        decoration: InputDecoration(
          labelText: 'Department/Shop',
          labelStyle: TextStyle(color: sl.text3, fontSize: 11.5),
          prefixIcon: Icon(Icons.business_rounded, size: 18, color: sl.text3),
          filled: true,
          fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.accent, width: 2)),
        ),
      ),
    );
  }

  Widget _buildDropdownField(String label, String value, List<String> items, ValueChanged<String?> onChanged, SL sl) {
    // The admin may legitimately empty a master list. Render a disabled
    // placeholder rather than crashing on items.first.
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: sl.text3, fontSize: 11.5),
            filled: true,
            fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          ),
          child: Text('Not configured — contact admin',
              style: TextStyle(color: sl.text3, fontSize: 12)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<String>(
        value: items.contains(value) ? value : items.first,
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(),
        onChanged: onChanged,
        dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
        style: TextStyle(color: sl.text1, fontSize: 12),
        icon: Icon(Icons.keyboard_arrow_down_rounded, color: sl.text3),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: sl.text3, fontSize: 11.5),
          filled: true,
          fillColor: sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.accent, width: 2)),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Container(
      color: Colors.transparent,
      child: SafeArea(
        child: Column(children: [
          if (widget.showAppBar)
            UniversalAppBar(
              title: I18n.t('nearMiss.title'),
              user: widget.user,
              toggleTheme: widget.toggleTheme,
              onSignOut: widget.onSignOut,
              isDark: widget.isDark,
            ),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ✅ Show listening banner when voice active
                _listeningBanner(sl),
                _guidanceBox(sl),
                _imageSection(sl),
                _detailsSection(sl),
                const SizedBox(height: 16),
                // ★ v31: Show "New Report" button if saved, otherwise show Save/Share/PDF
                if (_saved) ...[
                  // ★ Saved banner
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.green.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.green.withOpacity(0.3))),
                    child: Row(children: [
                      Icon(Icons.check_circle_rounded,
                        color: sl.greenText, size: 22),
                      const SizedBox(width: 10),
                      Expanded(child: Text(
                        'Report saved successfully!',
                        style: TextStyle(color: sl.greenText,
                          fontSize: 13, fontWeight: FontWeight.w700))),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  // ★ New Report button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _resetForm,
                      icon: const Icon(Icons.add_circle_outline_rounded,
                        color: Colors.white, size: 20),
                      label: const Text('New Report',
                        style: TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.w700)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                ] else ...[
                  // ★ v25: 3 action buttons — Save, Share Report, PDF
                  Row(children: [
                    Expanded(child: _submitBtn(
                      label: 'Save',
                      actionId: 'save',
                      icon:  Icons.save_rounded,
                      colors: const [Color(0xFF16A34A), Color(0xFF059669)],
                      onTap: _handleSaveOnly,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _submitBtn(
                      label: 'Share',
                      actionId: 'share',
                      icon:  Icons.share_rounded,
                      colors: const [Color(0xFFF59E0B), Color(0xFFF97316)],
                      onTap: _handleShareReport,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _submitBtn(
                      label: 'PDF',
                      actionId: 'pdf',
                      icon:  Icons.picture_as_pdf_rounded,
                      colors: const [Color(0xFF4F5BD5), Color(0xFF0EA5B5)],
                      onTap: _handleSavePdf,
                    )),
                  ]),
                ],
                const SizedBox(height: 20),
              ],
            ),
          )),
        ]),
      ),
    );
  }
}
