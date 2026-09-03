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
// package:http is deliberately NOT imported here. This screen has no business
// making raw HTTP calls — every network hop belongs in a service under
// lib/services/, which is where the backend URL override lives. The one direct
// call this file used to make (_callAiTextFallback) hardcoded the URL and so
// ignored that override.
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
import '../services/line_of_fire.dart';
import '../widgets/analysis_progress.dart';
import '../widgets/hazard_annotated_image.dart';
import '../widgets/universal_app_bar.dart';
import '../services/i18n.dart';
import '../services/groq_service.dart';
import '../services/near_miss_prompt.dart';
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
  // The full hazard list from the scan, kept only so the attached photo can be
  // annotated with bounding boxes and the line of fire. The FORM still reflects
  // the first hazard alone — this is about showing the reporter what the model
  // actually looked at, which is otherwise invisible on this screen.
  List<Map<String, dynamic>> _aiHazards = const [];
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
  // Deliberately UNSET. This used to default to '5. Equipment failure', which
  // meant every reporter who never opened the dropdown filed an equipment
  // failure — and the admin panel charts this field as "WSA-13 Pareto — Root
  // Causes". A default here is not a convenience, it is a fabricated root cause
  // that steers where safety effort goes. '' is the established unset sentinel
  // (see the master-list reconciliation in _loadMasterData) and _submit now
  // refuses to file without an explicit choice.
  String _wsaCause = '';
  String _severity = 'MEDIUM';
  // Deliberately unset. Pre-seeding this with 'Unsafe Condition' meant every
  // report that nobody touched the dropdown on was filed as an unsafe
  // condition, which is the same fabricated-data problem the WSA cause default
  // caused. '' means "not yet classified" and is caught by _submit.
  String _obsType  = '';

  String? _lastSubmissionKey;
  bool _submitting = false;
  String? _submittingAction; // tracks which button: 'save', 'share', 'pdf'
  bool _saved = false; // ★ v31: form has been saved, show "New Report" button

  // The saved record, kept so PDF and Share stay reachable AFTER saving.
  // Previously the whole Save/Share/PDF row was replaced by "New Report" the
  // moment _saved flipped true, so a reporter who tapped Save could never
  // obtain the PDF of the report they had just filed — the only route to one
  // was to fill the entire form again and tap PDF instead. These hold the
  // already-persisted incident so the post-save actions export THAT record
  // rather than submitting a second copy of it.
  Map<String, dynamic>? _savedIncident;
  String _savedReporterName = '';
  String _savedReporterPno = '';
  Uint8List? _savedImageBytes;
  bool _postSaveBusy = false;

  // Per-field validation errors, shown on the field itself. Snackbars were the
  // only feedback: they name the problem but not the place, they are gone in
  // three seconds, and on a long scrolling form the offending field is usually
  // off-screen when the message appears. Null means "no error".
  String? _errLocation;
  String? _errDescription;
  String? _errAction;
  String? _errWsa;
  String? _errObsType;

  // Marking a field in red only helps if the reporter can see it, and this form
  // is several screens long: a failed submit is usually triggered from the
  // button at the bottom while the empty location field sits far above the fold.
  // The keys are attached at the call sites via KeyedSubtree so the field
  // builders stay generic, and the scroll controller is the form's own —
  // Scrollable.ensureVisible finds the enclosing viewport from the context, but
  // the controller is what keeps that viewport addressable across rebuilds.
  final ScrollController _formScroll = ScrollController();
  final GlobalKey _keyLocation    = GlobalKey();
  final GlobalKey _keyDescription = GlobalKey();
  final GlobalKey _keyAction      = GlobalKey();
  final GlobalKey _keyWsa         = GlobalKey();
  final GlobalKey _keyObsType     = GlobalKey();

  // How the location field got its current value: '' (typed by hand), 'gps'
  // (device fix) or 'exif' (embedded in the photo). Recorded at each fill site
  // rather than guessed later — the hint text used to infer EXIF-vs-GPS from
  // whether the string contained a comma, which mislabels any reverse-geocoded
  // address that happens to have one.
  String _locSource = '';
  bool _locating = false;

  // Set when the AI filled the field, so the badge can say so and the reporter
  // knows what they are overriding. Each is cleared by that field's own
  // onChanged: once the reporter has touched it, the value is theirs and
  // labelling it as the AI's would misattribute their judgement.
  bool _obsTypeFromAi  = false;
  bool _wsaFromAi      = false;
  bool _severityFromAi = false;
  bool _actionFromAi   = false;

  /// The refined description the reporter last accepted, verbatim.
  ///
  /// Guards against the AI analysing its own prose. `_onDescriptionChanged`
  /// re-runs the classifier on any text over ten characters, and "Edit It"
  /// deliberately puts the caret in the description straight after accepting —
  /// so the very first keystroke used to send the AI's own rewording back for
  /// rewording, and the card would reappear grading itself while the previous
  /// `_aiSummary` still sat above it. Cleared once the reporter has changed
  /// enough of the text that it is theirs again, at which point re-analysis is
  /// wanted and resumes.
  String _acceptedAiText = '';

  // Which numbered step card the reporter is currently in, so it can be tinted.
  // Derived from descendant focus via a Focus wrapper per card rather than
  // tracked field by field: a FocusNode reports hasFocus for its whole subtree,
  // so any field added to a section later joins the group for free and there is
  // no per-field bookkeeping to forget. 0 means nothing on the form has focus
  // (the keyboard is closed), and then nothing is tinted — leaving the last
  // card lit would point the reporter at a place they have already left.
  int _activeStep = 0;

  // Held only so "Edit AI version" can put the caret in the description after
  // replacing its text. Without it the reporter is told they may edit and then
  // has to find and tap the field themselves.
  final FocusNode _fnDescription = FocusNode();

  // ★ v24: AI Description Refinement
  bool _aiRefining = false;
  // {hasHazard, category, refined, correctiveAction, wsaCause, severity,
  // reason, confidence, detectedLanguage}. `isNearMiss` used to be the field
  // this turned on; it is gone, because the question was never whether the
  // report was a near miss but what kind of observation it is.
  Map<String, dynamic>? _aiSuggestion;
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
        // Each of these three also drops its AI badge. This method is wired to
        // AdminMasterData.revision, so it can run mid-form: an admin edit that
        // blanks the value the AI chose would otherwise leave an "AI" chip
        // sitting on an empty dropdown, or — worse — on a fallback value the AI
        // never proposed. A badge that outlives the value it describes is the
        // one failure mode the badges were added to prevent.
        if (!_wsaCauses.contains(_wsaCause)) {
          _wsaCause = '';
          _wsaFromAi = false;
        }
        if (_selectedDept.isNotEmpty && !_departments.contains(_selectedDept)) {
          _selectedDept = '';
        }
        if (!_severities.contains(_severity)) {
          _severity = _severities.isNotEmpty ? _severities.first : '';
          _severityFromAi = false;
        }
        // Only rescue a value that is set but stale (e.g. the admin renamed the
        // type). '' is the intentional "not yet classified" sentinel and must
        // survive this, or the unset state gets silently filled in again.
        if (_obsType.isNotEmpty && !_obsTypes.contains(_obsType)) {
          _obsType = '';
          _obsTypeFromAi = false;
        }
      });
    } catch (_) {}
  }

  /// Reacts to a write that did NOT come from the keyboard.
  ///
  /// Setting `controller.text` in code does not fire the field's `onChanged`, so
  /// the badge-clearing and error-clearing that live there are skipped. The
  /// visible consequence: a reporter taps the mic and dictates over the AI's
  /// suggested corrective action, and their own words keep the "AI" chip —
  /// misattributing the reporter's judgement to the model, which is exactly
  /// backwards from what the chip is for. Call this from every programmatic
  /// write. Must be called inside a setState (all current callers are).
  void _noteProgrammaticWrite(TextEditingController field) {
    if (field == _immediateAction) {
      _actionFromAi = false;
      if (field.text.trim().isNotEmpty) _errAction = null;
    } else if (field == _description) {
      if (field.text.trim().isNotEmpty) _errDescription = null;
    } else if (field == _location) {
      if (field.text.trim().isNotEmpty) _errLocation = null;
    }
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
            _noteProgrammaticWrite(field);
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
    // Don't hand the AI its own words back. See _acceptedAiText.
    if (_acceptedAiText.isNotEmpty) {
      if (_stillSubstantiallyAiText(text)) return;
      _acceptedAiText = '';
    }
    if (text.trim().length >= 10) {
      _descDebounce = Timer(_aiRefineDelay, () {
        if (!mounted) return;
        if (_description.text.trim() == text.trim()) {
          _refineWithAI(text.trim());
        }
      });
    }
  }

  /// Whether [text] is still recognisably the AI wording in [_acceptedAiText].
  ///
  /// Measured as the share of the accepted text that survives untouched at the
  /// head and tail, which is what fixing one clause in the middle leaves behind.
  /// Above 70% retained, this is the reporter correcting a detail and there is
  /// nothing new for the classifier to read. Below it, they have rewritten the
  /// observation and a fresh reading is the point.
  bool _stillSubstantiallyAiText(String text) {
    final ai = _acceptedAiText.trim();
    if (ai.isEmpty) return false;
    final t = text.trim();
    if (t == ai) return true;
    var head = 0;
    while (head < t.length && head < ai.length && t[head] == ai[head]) {
      head++;
    }
    var tail = 0;
    while (tail < t.length - head &&
        tail < ai.length - head &&
        t[t.length - 1 - tail] == ai[ai.length - 1 - tail]) {
      tail++;
    }
    return (head + tail) >= ai.length * 0.7;
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
            _noteProgrammaticWrite(field);
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

      final body = await SyncService.callAiText(prompt);
      if (!mounted || body == null) return;

      String? aiText;
      if (body['text'] != null) aiText = body['text'].toString();
      else if (body['result'] != null) aiText = body['result'].toString();

      if (aiText != null && aiText.trim().isNotEmpty) {
        fieldOk = true;
        fieldProvider = 'apps_script';
        String cleaned = aiText.trim();
        if (cleaned.startsWith('```')) cleaned = cleaned.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll('```', '');
        if (cleaned.startsWith('"') && cleaned.endsWith('"')) cleaned = cleaned.substring(1, cleaned.length - 1);
        cleaned = cleaned.trim();

        if (cleaned.isNotEmpty && cleaned != rawText) {
          setState(() {
            field.text = cleaned;
            field.selection = TextSelection.fromPosition(TextPosition(offset: cleaned.length));
            _noteProgrammaticWrite(field);
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

      // ★ FALLBACK: Apps Script (Gemini) if Groq fails.
      // The prompt is built by NearMissPrompt, the single definition shared with
      // GroqService — so both providers are asked exactly the same question and
      // answer against the same master lists. The ~50 lines that used to sit
      // inline here were a hand-maintained copy that had already drifted.
      // The master lists come from this screen's own state, which is what the
      // dropdowns are built from, so a value the AI returns is a value the form
      // can actually accept.
      final prompt = NearMissPrompt.build(
        text: rawText,
        languageName: _detectedLangName,
        kbContext: kbContext,
        obsTypes: _obsTypes,
        wsaCauses: _wsaCauses,
        severities: _severities,
      );

      final body = await SyncService.callAiText(prompt);
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
            refineProvider = 'apps_script';
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

  // REMOVED: `_callAiTextFallback`. It re-posted the same {action:'gemini'}
  // payload, with the same text/plain content type, to the same Apps Script
  // deployment that `SyncService.callAiText` had just failed on — except it
  // pinned the URL as a compile-time constant instead of reading the
  // `sync_backend_url` prefs override, so on any deployment other than the
  // hardcoded one it was guaranteed to fail. It therefore added no fallback
  // value at all, only a second 30s timeout on top of the first: exactly the
  // CORS/ERR_FAILED pair and the 30s TimeoutException seen in the console.
  // If a genuine second text provider is ever wanted, add it as a distinct
  // service, not as a copy of the call that just failed.

  /// Applies the AI's answer to the form.
  ///
  /// Every value is put through the resolver for its own field first, so an
  /// off-list answer becomes '' and leaves the field alone rather than storing
  /// a category no dropdown offers. Each field it does set is flagged
  /// `*FromAi`, which draws the "AI" chip and is cleared the moment the reporter
  /// touches that field: the badge exists so nobody mistakes the model's guess
  /// for their own judgement, and a stale badge would do the reverse.
  ///
  /// With [thenEdit] the description keeps focus and the caret so the reporter
  /// can fix a clause immediately — the "Edit It" path, for the common case
  /// where the rephrasing is nearly right.
  void _acceptAiRefinement({bool thenEdit = false}) {
    if (_aiSuggestion == null) return;
    final refined = _aiSuggestion!['refined']?.toString() ?? '';
    final correctiveAction = _aiSuggestion!['correctiveAction']?.toString() ?? '';
    // Both text providers are asked for "category" as one of the admin's
    // observation types (GroqService.classifyNearMiss and the Apps Script
    // prompt below both build the rule from the same list), and the answer was
    // parsed into _aiSuggestion and then never read. Applied here so accepting
    // the AI's wording also accepts its classification.
    final aiObsType = _canonicalObsType(_aiSuggestion!['category']?.toString() ?? '');
    // The WSA cause goes through the same resolver the vision path uses, which
    // returns '' for anything that is not a member of the admin's list. This
    // field is charted as the root-cause Pareto, so an invented value would not
    // merely be wrong, it would be counted.
    final aiWsa = _canonicalWsa(_aiSuggestion!['wsaCause']?.toString() ?? '');
    // Severity has no resolver because it needs none: the list is four fixed
    // words, so exact membership after upper-casing is the whole test.
    final rawSeverity = _aiSuggestion!['severity']?.toString().trim().toUpperCase() ?? '';
    final aiSeverity = _severities.contains(rawSeverity) ? rawSeverity : '';
    // The rephrasing and the classification are applied independently. They used
    // to share one `if (refined.isNotEmpty)` gate, so a model that classified
    // the observation but returned no rewording dropped the category, the WSA
    // cause, the severity and the corrective action on the floor — while the
    // card above had already listed all four under "Accepting will also set:".
    // The reporter would tap accept, watch nothing happen, and have no way to
    // tell the difference between that and the app ignoring them.
    final applyText = refined.isNotEmpty;
    setState(() {
      if (applyText) {
        _description.text = refined;
        _description.selection = TextSelection.fromPosition(
            TextPosition(offset: refined.length));
        _aiSummary = _generateSummary(refined);
        _errDescription = null;
      }
      // ★ v35: Also populate corrective action if AI suggested one.
      // Never overwrites: whatever the reporter has already typed here is
      // their own remedy and outranks the model's.
      if (correctiveAction.isNotEmpty && _immediateAction.text.trim().isEmpty) {
        _immediateAction.text = correctiveAction;
        _immediateAction.selection = TextSelection.fromPosition(
            TextPosition(offset: correctiveAction.length));
        _actionFromAi = true;
        _errAction = null;
      }
      // Classification follows the wording it was derived from. All three are
      // left editable: the reporter saw the event and the model only read a
      // sentence about it, so the badge marks each as the AI's answer and any
      // change to that dropdown clears it. Applied BEFORE the snapshot below,
      // which has to record what the AI actually set — snapshotting `_severity`
      // first would store the pre-AI value and then read every later
      // comparison as an edit the reporter never made.
      if (aiObsType.isNotEmpty) {
        _obsType = aiObsType;
        _obsTypeFromAi = true;
        _errObsType = null;
      }
      if (aiWsa.isNotEmpty) {
        _wsaCause = aiWsa;
        _wsaFromAi = true;
        _errWsa = null;
      }
      if (aiSeverity.isNotEmpty) {
        _severity = aiSeverity;
        _severityFromAi = true;
      }
      // ★ Snapshot AI's refinement so later user edits can be detected.
      // Only when text was actually applied: `summary` is compared against
      // `_description` to decide whether the reporter reworded the AI, and
      // recording '' here would mark their own untouched text as an AI edit.
      if (applyText) {
        _aiOriginalSuggestion = {
          'summary':          refined,
          'correctiveAction': correctiveAction,
          'severity':         _severity,
        };
        _aiOriginalSource = _aiSuggestion?['_source']?.toString() ?? 'refinement';
        // Suppresses the debounced re-analysis that the next keystroke would
        // otherwise trigger. See _acceptedAiText.
        _acceptedAiText = refined;
      }
      _aiSuggestion = null;
    });
    if (thenEdit) {
      // Caret at the end rather than selecting the whole text: this is a
      // "fix one clause" affordance, and a select-all means the first
      // keystroke silently destroys the rephrasing they just accepted.
      _fnDescription.requestFocus();
      _description.selection = TextSelection.fromPosition(
          TextPosition(offset: _description.text.length));
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
    _formScroll.dispose();
    _fnDescription.dispose();
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
      _aiBrief = null; _aiHazards = const [];
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
              setState(() { _location.text = address; _locSource = 'exif'; });
            } else {
              // No address but have coords — show coords
              setState(() {
                _location.text =
                  '${exifLocation.latitude!.toStringAsFixed(5)}, ${exifLocation.longitude!.toStringAsFixed(5)}';
                _locSource = 'exif';
              });
            }
            if (_errLocation != null) setState(() => _errLocation = null);
          }
          return; // EXIF worked — don't need device GPS
        }
      } catch (_) {}
    }
    // Camera photos or EXIF extraction failed — use device GPS
    _captureGpsInBackground();
  }

  /// Reporter-initiated GPS fetch from the location field's crosshair button.
  /// Unlike [_captureGpsInBackground] this one is loud: it OVERWRITES whatever
  /// is in the field (the reporter asked for it) and reports failure instead of
  /// swallowing it, because a silent no-op on a deliberate tap reads as a broken
  /// button.
  Future<void> _useDeviceGps() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final location = await GeoService.getCurrentLocation().timeout(
        const Duration(seconds: 12),
        onTimeout: () => LocationData(error: 'GPS timeout'),
      );
      if (!mounted) return;
      if (location != null && location.isValid) {
        final address = GeoService.getDisplayAddress(location);
        setState(() {
          _capturedLocation = location;
          _location.text = address.isNotEmpty
              ? address
              : '${location.latitude!.toStringAsFixed(5)}, ${location.longitude!.toStringAsFixed(5)}';
          _locSource = 'gps';
          _errLocation = null;
          _locating = false;
        });
      } else {
        setState(() => _locating = false);
        _snack(
          location?.error?.isNotEmpty == true
              ? 'GPS unavailable: ${location!.error} — type the location instead'
              : 'GPS unavailable — type the location instead',
          AppColors.amber,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _locating = false);
      _snack('Could not get GPS — type the location instead', AppColors.amber);
    }
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
            setState(() {
              _location.text = address;
              _locSource = 'gps';
              _errLocation = null;
            });
          }
        }
      }
    } catch (_) {
      // GPS capture failed silently — user can fill manually
    }
  }

  /// Resolves whatever the model called the observation type onto a member of
  /// the admin's own [_obsTypes] list, and returns '' when it cannot.
  ///
  /// Both the text and the vision prompts are given the list verbatim, but a
  /// model still returns 'unsafe-act', 'Unsafe Acts', 'UNSAFE ACT' or a plain
  /// synonym often enough to matter. Matching case- and punctuation-insensitively
  /// is the difference between the classification landing in the record and
  /// being silently dropped in favour of whatever the field was initialised to.
  String _canonicalObsType(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '';
    if (_obsTypes.contains(v)) return v;

    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final target = norm(v);
    if (target.isEmpty) return '';

    for (final t in _obsTypes) {
      if (norm(t) == target) return t;
    }
    // Plural/possessive slack ('Unsafe Acts' → 'Unsafe Act') and containment,
    // which also catches 'Near Miss Event'. Accepted ONLY when exactly one type
    // matches: a bare 'Unsafe' is a prefix of both 'Unsafe Act' and 'Unsafe
    // Condition', and taking whichever the admin happened to list first would
    // put a coin-flip in the record while the badge presents it to the reporter
    // as the AI's considered answer. Ambiguous means unclassified.
    final prefixHits = <String>[];
    for (final t in _obsTypes) {
      final nt = norm(t);
      if (nt.isEmpty) continue;
      if (target.startsWith(nt) || nt.startsWith(target)) prefixHits.add(t);
    }
    if (prefixHits.length == 1) return prefixHits.first;
    // Anything else — including 'Line of Fire', which the vision prompts offer
    // to drive the lofZone overlay but which is not one of the form's own
    // observation types — is left for the reporter to choose. Mapping it onto
    // act-or-condition here would be a guess: standing under a suspended load
    // is an act, the suspended load is a condition, and the model's answer does
    // not say which it meant.
    return '';
  }

  /// Small "AI" chip shown on a field the model filled in, so the reporter can
  /// see what they are overriding rather than assuming they chose it.
  Widget _aiSetBadge(SL sl) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.accent.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.auto_awesome, size: 11, color: sl.accentText),
        const SizedBox(width: 3),
        // 10.5px, not 9: tools/audit_contrast.py fails anything under 10 and
        // this sits on a shop-floor screen read through a visor.
        Text('AI',
          style: TextStyle(color: sl.accentText, fontSize: 10.5, fontWeight: FontWeight.w800)),
      ]),
    ),
  );

  Map<String, dynamic> _applyHardenedV15Filters(String name, String desc, String action, String reg, String cause,
      [String obsType = '']) {
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
        // Was 'Equipment failure' — off-list, because the WSA-13 member carries
        // a '5. ' prefix. Resolved so it charts as itself.
        'cause': _canonicalWsa('5. Equipment failure'),
        // Fixed hardware in a safe configuration: a condition, not an act. Run
        // through the resolver so a plant that renamed its observation types
        // still gets a value its own dropdown accepts.
        'obsType': _canonicalObsType('Unsafe Condition'),
      };
    }
    // obsType is the model's classification, resolved onto the admin's list.
    // This used to echo back `_obsType` — the field's own current value — so the
    // AI's answer was discarded and every photo report inherited the initial
    // 'Unsafe Condition' unless the reporter changed it by hand.
    return {
      'name': name, 'desc': desc, 'action': action, 'reg': reg, 'cause': cause,
      'obsType': _canonicalObsType(obsType),
    };
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
        _aiHazards = const [];
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
          _aiHazards = const [];
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
      // The vision prompt already asks each hazard for a "type" drawn from the
      // admin's own observation types (see {{OBS_TYPES}} in gemini_vision.dart),
      // and this screen simply never read it — so the model's classification was
      // computed, returned, displayed in the AI Scan tab, and thrown away here.
      String rawObsType = first?['type']?.toString() ?? '';

      final refinedData = _applyHardenedV15Filters(rawName, rawDesc, rawAction, rawReg, rawCause, rawObsType);

      final sev        = (first?['severity']?.toString() ?? 'MEDIUM').toUpperCase();
      // HazardValidator scores each hazard individually, and this screen shows
      // exactly ONE of them, so the per-hazard figure is the honest one here —
      // the report-level number describes findings the user never sees.
      // The citation verdict is only carried through when the hardened filter
      // has not swapped the citation out from under it; a verdict about a
      // reference that is no longer displayed would be worse than none.
      final regUnchanged = (refinedData['reg']?.toString() ?? '') == rawReg;

      // Copied defensively: the annotated photo must not hold a live reference
      // into the raw model response, and a non-Map entry in the list would break
      // the overlay for every other hazard in it.
      final annotatable = <Map<String, dynamic>>[
        for (final h in hazards)
          if (h is Map) Map<String, dynamic>.from(h),
      ];
      // isOnline already declared above (line ~381)

      final user              = await LocalDB.getCurrentUser();
      String plantFromProfile = user?['plant']?.toString() ?? _plant;
      if (!_plants.contains(plantFromProfile)) plantFromProfile = _plant;

      setState(() {
        _isOnlineMode = isOnline;
        _aiHazards = annotatable;
        _aiBrief = {
          'identified': refinedData['name'],
          'statutory':  (refinedData['reg']?.toString() ?? '').isEmpty ? 'Refer Factories Act S35-41' : refinedData['reg'].toString(),
          'type':       refinedData['obsType'],
          'severity':   sev,
          'confidence': first?['confidence'] ?? result?['confidence'] ?? 75,
          'needsReview': first?['needsReview'] == true,
          'regChecked': regUnchanged && first?['confidenceReasons'] is List,
          'regVerified': regUnchanged && first?['regulationVerified'] == true,
          'regIssue': regUnchanged
              ? (first?['regulationIssue']?.toString() ?? '')
              : '',
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
            // Only claim a source if one was not already recorded by the EXIF
            // path — this branch cannot tell the two apart on its own.
            if (_locSource.isEmpty) _locSource = 'gps';
          } else {
            _location.text = 'To be confirmed (edit if needed)';
            _locSource = '';
          }
        }
        _plant                = plantFromProfile;
        // Resolved, not trusted: the model is free to invent a category string,
        // and an unresolvable one must leave the field unset for the reporter
        // rather than land off-list in the root-cause Pareto.
        _wsaCause             = _canonicalWsa(refinedData['cause']?.toString() ?? '');
        // Membership-checked against the admin's list for the same reason the
        // text path checks it. `sev` is `severity ?? 'MEDIUM'` straight off the
        // model, so an off-list answer used to be assigned here and then
        // displayed as _severities.first by the dropdown's fallback — the
        // reporter saw one value, the record carried another.
        final aiSeverity = _severities.contains(sev) ? sev : '';
        if (aiSeverity.isNotEmpty) _severity = aiSeverity;
        // Badged for the same reason as the text path: these came from a photo
        // the model read, not from the reporter, and the chip is what tells them
        // apart. Only claimed when a value actually landed — badging an empty or
        // reporter-chosen field as AI-filled is a false claim in the direction
        // that matters, since the badge is what licenses a reviewer to doubt it.
        _wsaFromAi            = _wsaCause.isNotEmpty;
        _severityFromAi       = aiSeverity.isNotEmpty;
        // The photo path fills corrective action 1 above (`_immediateAction`),
        // so it owes the same badge the text path gives it.
        _actionFromAi         = _immediateAction.text.trim().isNotEmpty;
        // Only overwrite when the model gave something resolvable; an
        // unrecognisable answer leaves the reporter's own choice alone rather
        // than blanking a dropdown they may already have set.
        final aiObsType = refinedData['obsType']?.toString() ?? '';
        if (aiObsType.isNotEmpty) {
          _obsType = aiObsType;
          _obsTypeFromAi = true;
        }
        _analyzing            = false;
        // ★ Snapshot the AI's suggested values so we can detect user edits.
        _aiOriginalSuggestion = {
          'summary':          refinedData['desc']?.toString() ?? '',
          'correctiveAction': refinedData['action']?.toString() ?? '',
          // The value actually applied, not the raw model answer: this snapshot
          // is compared against `_severity` later to decide whether the reporter
          // overrode the AI, and recording an off-list `sev` that was never
          // applied would read every submission as an override.
          'severity':         _severity,
        };
        _aiOriginalSource = (result?['_source'] ?? (isOnline ? 'online' : 'offline')).toString();
        // Same guard as the accept path: the description filled above was
        // written by the vision model, so the text classifier must not be handed
        // it straight back the moment the reporter adjusts a word of it.
        _acceptedAiText = _description.text;
      });
    } catch (e) {
      setState(() {
        _isOnlineMode = false;
        _aiHazards = const [];
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

  /// Resolves any incoming string onto a member of the live [_wsaCauses] master
  /// list, or returns '' (unset) if it cannot be resolved with confidence.
  ///
  /// Every writer of [_wsaCause] that is not the user's own dropdown must go
  /// through here. Three separate code paths used to write values that were not
  /// in the WSA-13 list at all — the hazard-type map below, the hardened filter
  /// (which returned 'Equipment failure' with no number prefix), and the raw
  /// model output on the text path. The analytics screens then had to re-attach
  /// the strays by fuzzy keyword matching, so the stored classification and the
  /// charted classification were different values.
  ///
  /// Matching is by exact string, then by leading number ('5.'), then by the
  /// label text with the number stripped. Deliberately no keyword guessing:
  /// a wrong cause is worse than an absent one, because an absent one prompts a
  /// human and a wrong one silently becomes the Pareto.
  String _canonicalWsa(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '';
    if (_wsaCauses.contains(v)) return v;

    String stripNum(String s) {
      final i = s.indexOf('.');
      final head = i > 0 ? s.substring(0, i) : '';
      if (head.isNotEmpty && int.tryParse(head) != null) {
        return s.substring(i + 1).trim().toLowerCase();
      }
      return s.trim().toLowerCase();
    }

    final dot = v.indexOf('.');
    final lead = dot > 0 ? v.substring(0, dot) : '';
    if (lead.isNotEmpty && int.tryParse(lead) != null) {
      for (final c in _wsaCauses) {
        if (c.startsWith('$lead.')) return c;
      }
    }

    final target = stripNum(v);
    for (final c in _wsaCauses) {
      if (stripNum(c) == target) return c;
    }
    return '';
  }

  /// Maps an AI hazard category onto a WSA-13 cause, and returns '' when the
  /// hazard type does not determine a cause.
  ///
  /// This deliberately maps far less than it used to. The old version turned
  /// every hazard into one of seven labels ('Fall from Height', 'Electrical',
  /// 'Burn / Fire', 'Gas Related', 'Machine / Equipment', 'Slip / Fall',
  /// 'Other') — none of which were WSA-13 members. Beyond being off-list, the
  /// mapping was a category error: a hazard TYPE is not a CAUSE. "Fall from
  /// height" does not tell you whether the cause was a missing procedure, no
  /// supervision, or a failed anchor point, and picking one on the reporter's
  /// behalf fabricates the very number the Pareto chart is built from.
  ///
  /// So only the near-tautological case is mapped, and everything else is left
  /// for the human who was standing there. That costs one dropdown tap and buys
  /// a root-cause distribution that means something.
  String _mapToWsaCause(String category, String name) {
    final c = category.toUpperCase();
    final n = name.toLowerCase();
    if (c == 'HOUSEKEEPING' ||
        n.contains('housekeeping') ||
        n.contains('spill') ||
        n.contains('debris') ||
        n.contains('clutter')) {
      return _canonicalWsa('8. Poor housekeeping');
    }
    return '';
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
      _pickedFile = null; _imageBytes = null; _aiBrief = null; _aiHazards = const [];
      _brief.clear(); _deptOther.clear(); _selectedDept = ''; _showOtherDept = false;
      _location.clear(); _description.clear(); _immediateAction.clear();
      for (final c in _additionalActions) { c.dispose(); }
      _additionalActions.clear();
      _aiSummary = null;
      _lastSubmissionKey = null;
      // Drop the previous record so the post-save PDF/Share actions can never
      // export the last report while the reporter is filling in the next one.
      _savedIncident = null;
      _savedImageBytes = null;
      _savedReporterName = '';
      _savedReporterPno = '';
      _postSaveBusy = false;
      _clearFieldErrors();
      _locSource = '';
      _obsTypeFromAi = false;
      _wsaFromAi = false;
      _severityFromAi = false;
      _actionFromAi = false;
      _acceptedAiText = '';
      _activeStep = 0;
      // The suggestion card and its snapshot belonged to the report that was
      // just filed. Left standing, the next report opens with the previous
      // one's AI reading on screen.
      _aiSuggestion = null;
      _aiOriginalSuggestion = null;
      _aiOriginalSource = null;
      // The WSA cause and observation type are per-incident judgements, not
      // sticky preferences: carrying them into the next report is how the
      // previous one's classification silently becomes the default.
      _wsaCause = '';
      _obsType = '';
    });
  }

  /// Brings the first field carrying a validation error into view.
  ///
  /// The inline errors are useless on their own on a form this long: the Save
  /// button sits at the bottom, so an empty location field two screens up is
  /// marked in red where nobody can see it, and the snackbar this replaced had
  /// exactly the same blind spot. Ordered to match the visual order of the
  /// fields, not the order they are validated in.
  ///
  /// Posted to the next frame because the errors are set in the same setState
  /// that calls this: the red [errorText] rows do not exist yet, so the offsets
  /// measured now would be the pre-error layout's. A null currentContext is
  /// normal rather than exceptional — the field may be inside a collapsed
  /// section — so it is skipped rather than asserted on.
  void _scrollToFirstError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targets = <GlobalKey>[
        // Location sits ABOVE both dropdowns in _detailsSection (plant, dept,
        // location, WSA, obs type, severity). Listing the dropdowns first meant
        // a blank-form submit — where all five errors fire at once, the common
        // case — scrolled to WSA and left the location error off-screen above
        // it, which is the precise blind spot this function exists to close.
        if (_errLocation != null) _keyLocation,
        if (_errWsa != null) _keyWsa,
        if (_errObsType != null) _keyObsType,
        if (_errDescription != null) _keyDescription,
        if (_errAction != null) _keyAction,
      ];
      for (final k in targets) {
        final ctx = k.currentContext;
        if (ctx == null) continue;
        Scrollable.ensureVisible(
          ctx,
          // Not 0.0: flush against the top edge puts the field under the app
          // bar's shadow and hides the label above it.
          alignment: 0.15,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
        return;
      }
    });
  }

  /// Clears every inline validation error. Call inside an existing setState.
  void _clearFieldErrors() {
    _errLocation = null;
    _errDescription = null;
    _errAction = null;
    _errWsa = null;
    _errObsType = null;
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

  /// Exports the PDF of the report that was ALREADY saved. Deliberately does
  /// not go through _submit: the record exists, and re-submitting to obtain a
  /// document would file a second copy of the same near miss.
  Future<void> _exportSavedPdf() async {
    final incident = _savedIncident;
    if (incident == null || _postSaveBusy) return;
    setState(() => _postSaveBusy = true);
    try {
      await PdfExport.downloadOrShareIncident(
        incident: incident,
        reporterName: _savedReporterName.isEmpty
            ? 'SAIL Safety Officer'
            : _savedReporterName,
        reporterPno: _savedReporterPno,
        imageBytes: _savedImageBytes,
      );
    } catch (e) {
      if (mounted) _snack('PDF export failed: $e', AppColors.red);
    } finally {
      if (mounted) setState(() => _postSaveBusy = false);
    }
  }

  /// Shares the report that was already saved, reusing the same builder the
  /// success dialog uses so the text cannot drift between the two routes.
  Future<void> _shareSavedReport() async {
    final incident = _savedIncident;
    if (incident == null || _postSaveBusy) return;
    setState(() => _postSaveBusy = true);
    try {
      await _shareViaWhatsApp(incident, _savedImageBytes);
    } catch (e) {
      if (mounted) _snack('Share failed: $e', AppColors.red);
    } finally {
      if (mounted) setState(() => _postSaveBusy = false);
    }
  }

  Future<bool> _submit({bool exportAfter = false}) async {
    if (_submitting) return false; // Prevent double-tap

    // Every required field is checked in one pass and each failure is marked on
    // the field itself. Returning on the first failure with only a snackbar
    // meant the reporter fixed one field, tapped Save, was refused again for a
    // different field they could not see, and had no way to know how many more
    // were waiting. The snackbar is kept as a secondary cue for whatever is
    // scrolled out of view.
    final loc = _location.text.trim();
    final desc = _description.text.trim();
    final hasAction = _immediateAction.text.trim().isNotEmpty ||
        _additionalActions.any((c) => c.text.trim().isNotEmpty);

    final locErr = (loc.isEmpty || loc == 'To be confirmed (edit if needed)')
        ? 'Enter the actual location'
        : null;
    final descErr = (desc.isEmpty && _brief.text.trim().isEmpty)
        ? 'Describe what happened'
        : null;
    final actionErr = hasAction ? null : 'Add at least one corrective action';
    // The observation category is charted as the root-cause Pareto, so it has
    // to be a human judgement rather than whatever the field happened to be
    // initialised to. Guarded here rather than defaulted above on purpose.
    final wsaErr = _wsaCauses.contains(_wsaCause)
        ? null
        : 'Choose an observation category';
    // Same reasoning for the type. The AI fills this in when it can classify
    // the observation, so in the normal flow the reporter never sees this
    // error — it only fires when nothing classified it, and act-vs-condition
    // vs-near-miss is the distinction the whole statistic rests on.
    final obsTypeErr = _obsTypes.contains(_obsType)
        ? null
        : 'Choose the observation type';

    if (locErr != null || descErr != null || actionErr != null ||
        wsaErr != null || obsTypeErr != null) {
      setState(() {
        _errLocation = locErr;
        _errDescription = descErr;
        _errAction = actionErr;
        _errWsa = wsaErr;
        _errObsType = obsTypeErr;
        _submittingAction = null;
      });
      _scrollToFirstError();
      final missing = <String>[
        if (locErr != null) 'location',
        if (descErr != null) 'description',
        if (actionErr != null) 'corrective action',
        if (wsaErr != null) 'observation category',
        if (obsTypeErr != null) 'observation type',
      ];
      _snack(
        missing.length == 1
            ? 'Please fill the ${missing.first} — marked in red'
            : 'Please fill ${missing.length} required fields — marked in red',
        AppColors.red,
      );
      return false;
    }
    if (_errLocation != null || _errDescription != null ||
        _errAction != null || _errWsa != null || _errObsType != null) {
      setState(_clearFieldErrors);
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
          // Retained so the post-save PDF/Share actions can export THIS record
          // without re-running _submit, which would file a duplicate.
          _savedIncident = Map<String, dynamic>.from(incident);
          _savedReporterName = user?['name']?.toString() ?? 'SAIL Safety Officer';
          _savedReporterPno = user?['pno']?.toString() ?? '';
          _savedImageBytes = preservedImageBytes;
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

  /// Post-save action button (PDF / Share). Separate from [_submitBtn] because
  /// nothing is being submitted here — the record is already filed, so the
  /// label must never read "Saving..." and the busy state is _postSaveBusy.
  Widget _postSaveBtn({
    required String label,
    required IconData icon,
    required List<Color> colors,
    required Future<void> Function() onTap,
    required SL sl,
  }) {
    return AbsorbPointer(
      absorbing: _postSaveBusy,
      child: Opacity(
        opacity: _postSaveBusy ? 0.6 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: colors),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(color: colors.first.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 3)),
            ]),
          child: ElevatedButton.icon(
            onPressed: () => onTap(),
            icon: Icon(icon, size: 15, color: Colors.white),
            label: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 13),
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
    // The margin stays outside _stepCard: the card's own decoration animates,
    // and an animating container that also owns the gap between cards makes the
    // whole column shift when the highlight moves.
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _stepCard(
        step: 1,
        sl: sl,
        children: [
          _stepLabel('1', 'Image Evidence (Optional)', sl),
          const SizedBox(height: 12),
          if (_imageBytes == null && !_analyzing) _emptyImage(sl),
          if (_analyzing) _analyzingImage(),
          if (_imageBytes != null && !_analyzing && _aiBrief != null) _imageWithBrief(sl),
          if (_imageBytes != null && !_analyzing && _aiBrief == null) _imageAttachedOnly(sl),
        ],
      ),
    );
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

  /// Whether there is anything to draw on the photo. A hazard with neither a
  /// bbox nor a line of fire would render an annotated image indistinguishable
  /// from the plain one, plus a caption promising markings that aren't there.
  bool get _annotatable =>
      _imageBytes != null &&
      _aiHazards.any((h) =>
          h['bbox'] != null || LineOfFireGeometry.parse(h) != null);

  int get _lofCount =>
      _aiHazards.where((h) => LineOfFireGeometry.parse(h) != null).length;

  Widget _annotationCaption(SL sl) {
    final boxes = _aiHazards.where((h) => h['bbox'] != null).length;
    final lofs = _lofCount;
    final parts = <String>[
      if (boxes > 0) boxes == 1 ? '1 hazard boxed' : '$boxes hazards boxed',
      if (lofs > 0)
        lofs == 1 ? '1 line of fire marked' : '$lofs lines of fire marked',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 5),
          child: Icon(
            lofs > 0 ? Icons.arrow_outward_rounded : Icons.crop_free_rounded,
            size: 12,
            color: lofs > 0 ? sl.redText : sl.accentText),
        ),
        Expanded(
          child: Text(
            lofs > 0
              ? '${parts.join(' · ')}. The red arrow runs from the energy '
                'source to the person in its path.'
              : '${parts.join(' · ')} by AI. Check each one on site.',
            style: TextStyle(
              color: lofs > 0 ? sl.redText : sl.accentText,
              fontSize: 9.5,
              height: 1.35,
              fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _imageWithBrief(SL sl) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // The photo carries the AI's own markings: a box round each hazard and,
      // where a person stands in the path of an energy source, the line of fire.
      // Without them the reporter is asked to confirm a finding without being
      // shown WHERE in the picture it is — and the line of fire is the one thing
      // that names who would have been hurt.
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 250),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _annotatable
            ? HazardAnnotatedImage(
                imageBytes: _imageBytes!,
                hazards: _aiHazards,
              )
            : Image.memory(_imageBytes!,
                fit: BoxFit.contain, width: double.infinity),
        ),
      ),
      if (_annotatable) ...[
        const SizedBox(height: 6),
        _annotationCaption(sl),
      ],
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
          // Outcome of checking that citation against the citable table and the
          // plant's own knowledge base. Shown directly beneath the citation
          // because that is the only place it means anything.
          if (_aiBrief!['regChecked'] == true)
            Padding(
              // Indented to line up with the value column of _briefRow (80px
              // label), minus room for the leading icon.
              padding: const EdgeInsets.only(left: 80, bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 4),
                  child: Icon(
                    _aiBrief!['regVerified'] == true
                      ? Icons.verified_outlined : Icons.help_outline,
                    size: 11,
                    color: _aiBrief!['regVerified'] == true
                      ? sl.greenText : sl.amberText)),
                Expanded(child: Text(
                  _aiBrief!['regVerified'] == true
                    ? 'Citation verified against the reference table'
                    : ((_aiBrief!['regIssue']?.toString() ?? '').isNotEmpty
                        ? _aiBrief!['regIssue'].toString()
                        : 'Citation could not be verified — confirm before issuing'),
                  style: TextStyle(
                    color: _aiBrief!['regVerified'] == true
                      ? sl.greenText : sl.amberText,
                    fontSize: 9.5, height: 1.3, fontWeight: FontWeight.w600))),
              ])),
          _briefRow('Type',       _aiBrief!['type'].toString(),       sl),
          if (_aiBrief!['needsReview'] == true) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.10),
                border: Border.all(color: AppColors.amber.withOpacity(0.5)),
                borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(Icons.person_search_outlined, size: 13, color: sl.amberText),
                const SizedBox(width: 7),
                Expanded(child: Text(
                  'Worth confirming on site — the app could not fully '
                  'corroborate this finding. Edit anything that looks wrong '
                  'before submitting.',
                  style: TextStyle(color: sl.amberText, fontSize: 9.5, height: 1.35))),
              ])),
          ],
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
        onPressed: () => setState(() { _pickedFile = null; _imageBytes = null; _aiBrief = null; _aiHazards = const []; _brief.clear(); }),
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
  /// A numbered step card that lights up while the reporter is working inside it.
  ///
  /// The highlight is driven by descendant focus rather than by any bookkeeping
  /// at the field level: a [FocusNode] reports `hasFocus` for its entire subtree,
  /// so a field added to a card later is included automatically and there is no
  /// list of nodes to keep in step. `canRequestFocus: false` and
  /// `skipTraversal: true` keep this wrapper out of the tab order — without them
  /// the card itself becomes a focus stop, and the reporter tabs onto a
  /// container between every field.
  ///
  /// Deliberately a *fill* change and a border, not a text colour change:
  /// `tools/audit_contrast.py` fails coloured text on these backgrounds, and the
  /// tint is decoration behind content that must stay as readable as it was. The
  /// wash is kept very light for the same reason — 4% dark / 5% light measured
  /// against `sl.card`, which is a visible shift without dropping any label
  /// below AA.
  Widget _stepCard({
    required int step,
    required SL sl,
    required List<Widget> children,
  }) {
    final active = _activeStep == step;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (hasFocus) {
        if (!mounted) return;
        // Only ever claims or releases its own step. Writing `_activeStep = 0`
        // unconditionally on a lost focus would race the card that just gained
        // it — Flutter reports the loss after the gain, so moving between two
        // cards would leave nothing highlighted.
        if (hasFocus) {
          if (_activeStep != step) setState(() => _activeStep = step);
        } else if (_activeStep == step) {
          setState(() => _activeStep = 0);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: active
              ? Color.alphaBlend(
                  AppColors.accent.withOpacity(sl.isDark ? 0.04 : 0.05), sl.card)
              : sl.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? AppColors.accent.withOpacity(0.45)
                : Colors.transparent,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: active
                  ? AppColors.accent.withOpacity(sl.isDark ? 0.18 : 0.12)
                  : Colors.black.withOpacity(sl.isDark ? 0.2 : 0.06),
              blurRadius: active ? 16 : 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  /// Step 2 — the classification fields: who, where, and how bad.
  Widget _detailsSection(SL sl) => _stepCard(
    step: 2,
    sl: sl,
    children: [
      _stepLabel('2', 'Observation Particulars', sl),
      const SizedBox(height: 14),
            _buildDropdownField('Plant/Unit', _plant, _plants, (v) => setState(() => _plant = v!), sl),
            _buildDeptDropdown(sl),
            if (_showOtherDept)
              _buildTextField('Enter Department Name', _deptOther, Icons.edit_outlined, sl),
            KeyedSubtree(key: _keyLocation, child: _buildLocationField(sl)),
            KeyedSubtree(key: _keyWsa,
              child: _buildDropdownField('Observation Category (WSA 13)', _wsaCause, _wsaCauses,
                (v) => setState(() {
                  _wsaCause = v ?? '';
                  _wsaFromAi = false;
                  _errWsa = null;
                }), sl,
                requireChoice: true, errorText: _errWsa,
                badge: _wsaFromAi ? _aiSetBadge(sl) : null)),
            // Classified by the AI when it analysed the photo or the spoken
            // description; the reporter can still override, and the badge says
            // which of the two is currently in force.
            KeyedSubtree(key: _keyObsType,
              child: _buildDropdownField('Observation Type', _obsType, _obsTypes,
                (v) => setState(() {
                  _obsType = v ?? '';
                  _obsTypeFromAi = false;
                  _errObsType = null;
                }), sl,
                requireChoice: true, errorText: _errObsType,
                badge: _obsTypeFromAi ? _aiSetBadge(sl) : null)),
            // The dropdown above is never locked. This line exists because a
            // pre-filled field reads as a decision already taken: whoever saw the
            // event knows whether anything actually nearly happened, and the model
            // only had a photo or a sentence.
            if (_obsTypeFromAi)
              Padding(
                padding: const EdgeInsets.only(left: 14, top: 0, bottom: 12),
                child: Row(children: [
                  Icon(Icons.edit_outlined, size: 11, color: sl.accentText.withOpacity(0.8)),
                  const SizedBox(width: 4),
                  Expanded(child: Text(
                    'Classified by AI — tap to change it if you disagree',
                    style: TextStyle(color: sl.accentText.withOpacity(0.9),
                      fontSize: 10.5, fontStyle: FontStyle.italic),
                  )),
                ]),
              ),
            _buildDropdownField('Initial Risk Severity', _severity, _severities,
                (v) => setState(() { _severity = v!; _severityFromAi = false; }), sl,
                badge: _severityFromAi ? _aiSetBadge(sl) : null),
            // ★ Reference image now shown in _imageSection at top (via _imageAttachedOnly)
    ],
  );

  /// Step 3 — the account of the event and what was done about it.
  ///
  /// Split out of [_detailsSection], which was a single 180-line card holding
  /// everything from Plant/Unit down to the last corrective action. It was one
  /// card only because it grew that way, and the active-section tint made the
  /// cost visible: highlighting "the section being worked in" lit up almost the
  /// whole form, which tells the reporter nothing. The seam is where the fields
  /// stop being classification and start being narrative.
  Widget _descriptionSection(SL sl) => _stepCard(
    step: 3,
    sl: sl,
    children: [
      _stepLabel('3', 'What Happened & Action Taken', sl),
      const SizedBox(height: 14),
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
            KeyedSubtree(key: _keyDescription,
              child: _buildTextField('Tap mic → speak in ${_selectedVoiceLang == "hi" ? "Hindi" : "English"} → AI frames it', _description, Icons.description_outlined, sl, maxLines: 3,
                suffix: _micButton(_description),
                required_: true,
                errorText: _errDescription,
                focusNode: _fnDescription,
                onChanged: (v) {
                  if (_errDescription != null) setState(() => _errDescription = null);
                  _onDescriptionChanged(v);
                })),
            // ★ AI Suggestion Card
            if (_aiRefining)
              _buildAiRefiningIndicator(sl),
            if (_aiSuggestion != null)
              _buildAiSuggestionCard(sl),
            KeyedSubtree(key: _keyAction,
              child: _buildTextField('Corrective Action 1', _immediateAction, Icons.flash_on_outlined, sl, maxLines: 2,
                suffix: _micButton(_immediateAction),
                required_: true,
                errorText: _errAction,
                badge: _actionFromAi ? _aiSetBadge(sl) : null,
                onChanged: (v) {
                  if (_errAction != null && v.trim().isNotEmpty) {
                    setState(() => _errAction = null);
                  }
                  if (_actionFromAi) setState(() => _actionFromAi = false);
                  _onActionChanged(v);
                })),
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
  );

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

  /// Fill colour for an observation-type pill.
  ///
  /// WHY THESE HUES AND NOT THE OBVIOUS ONES
  /// Red, amber and green are spoken for: this app uses them for CRITICAL/HIGH,
  /// MEDIUM and safe-or-closed, and the severity chip sits a few lines below
  /// this pill inside the same card. A red "Unsafe Act" pill would read as a
  /// severity claim about the act, which is a different statement entirely and
  /// not one the model made here. So the type palette is drawn only from hues
  /// that carry no safety meaning in this interface.
  ///
  /// The fills are OPAQUE and paired with white text rather than tinted over the
  /// card. That is deliberate: the confidence badge above had to fall back to a
  /// near-white base in light mode because a 15% tint over the card's lavender
  /// fill dropped its text under AA. An opaque pill has the same contrast on
  /// every surface and in both themes, so it cannot be broken by a later change
  /// to the card colour. Measured against white with tools/audit_contrast.py's
  /// formula: teal 5.47:1, indigo 7.88:1, violet 7.10:1, rose 6.04:1, slate
  /// 7.58:1 — all above AA. Changing any hex means re-measuring.
  ///
  /// Anything unrecognised — including 'Line of Fire' — gets the neutral slate
  /// rather than a colour invented on the spot. Line of Fire is arguably the
  /// gravest type, but every hue that would say so is a severity colour, and
  /// implying a severity the model did not report would be worse than leaving it
  /// neutral.
  static Color _obsTypeColor(String type) {
    switch (type.trim().toLowerCase()) {
      case 'unsafe act':
        return const Color(0xFF0F766E); // teal-700 — a behaviour
      case 'unsafe condition':
        return const Color(0xFF3B45B0); // indigo-700 — a physical state
      case 'near miss':
        return const Color(0xFF6D28D9); // violet-700 — an event that happened
      case 'first aid case':
        return const Color(0xFFBE185D); // rose-700 — someone was hurt
      default:
        return const Color(0xFF475569); // slate-600 — no claim made
    }
  }

  /// Foreground for an observation-type label drawn on a TINTED chip rather than
  /// on an opaque pill.
  ///
  /// Needed for the same reason `sl.redText`/`sl.accentText` exist: no single hex
  /// works as text in both themes. The fills from [_obsTypeColor] are chosen to
  /// be legible under white, which makes them too dark to read on the outline
  /// chips in dark mode, where the chip is only a 10% wash of the tint over the
  /// card. So each type carries a dark ink for light mode and a light one for
  /// dark, measured against the real chip fill in each theme (white-over-lavender
  /// #FCFDFF, and the 10% wash over #171F2C):
  ///
  ///   Unsafe Act       5.38:1 light / 7.31:1 dark
  ///   Unsafe Condition 7.74:1 light / 4.78:1 dark
  ///   Near Miss        6.98:1 light / 5.19:1 dark
  ///   First Aid Case   5.93:1 light / 5.35:1 dark
  ///   other            7.45:1 light / 5.47:1 dark
  ///
  /// The dark-mode Unsafe Condition figure is the tightest at 4.78:1, so it is
  /// the one that breaks first: raising the chip's tint opacity, darkening the
  /// card, or nudging any of these hexes means re-measuring THAT pair before the
  /// others. audit_contrast.py scores tokens against the two global backgrounds
  /// and cannot see a local card fill, so this cannot be delegated to it.
  static Color _obsTypeInk(String type, bool isDark) {
    switch (type.trim().toLowerCase()) {
      case 'unsafe act':
        return isDark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E);
      case 'unsafe condition':
        return isDark ? const Color(0xFF818CF8) : const Color(0xFF3B45B0);
      case 'near miss':
        return isDark ? const Color(0xFFA78BFA) : const Color(0xFF6D28D9);
      case 'first aid case':
        return isDark ? const Color(0xFFFB7185) : const Color(0xFFBE185D);
      default:
        return isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);
    }
  }

  /// The observation type as a filled pill, for use inside the AI card.
  Widget _obsTypePill(String type) {
    final fill = _obsTypeColor(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(20),
        // A hairline lift of the same hue, so the pill still has an edge when it
        // lands on a card fill close to its own colour.
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: Text(
        type,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  /// The AI's reading of the typed or dictated description.
  ///
  /// This card used to be a gate. The model was asked "is this a near miss?",
  /// and on `false` the reporter got a red "Does NOT Qualify as Near Miss"
  /// panel, a "Try Again" button, and nothing else — the rephrasing and the
  /// suggested corrective action were both rendered only `if (isNearMiss)`. On a
  /// screen titled "Near Miss / Unsafe Condition" that is the wrong question:
  /// "one person was walking and there was a slippery surface" is a textbook
  /// unsafe condition, and the app answered it by refusing the report and asking
  /// a shop-floor worker to guess what wording would satisfy it. The likeliest
  /// outcome of that is not a better report, it is no report.
  ///
  /// So it now classifies. The model returns the observation type, and the card
  /// presents that alongside the rephrasing and the other fields it can fill,
  /// with three ways out: take it, take it and edit it, or keep your own words.
  /// The only state that still refuses is `hasHazard == false`, which means no
  /// safety content at all — and even that only warns.
  Widget _buildAiSuggestionCard(SL sl) {
    // Absent means present: an older response, or a model that ignored the
    // field, must not be read as "no hazard" and silently gate the card again.
    // The string "false" is tested alongside the bool because these models
    // return it often enough; without that, a genuine no-hazard verdict would
    // read as a hazard and the card would offer to fill four fields from it.
    final rawHasHazard = _aiSuggestion!['hasHazard'];
    final hasHazard = !(rawHasHazard == false || rawHasHazard == 'false');
    final confidence = (_aiSuggestion!['confidence'] ?? 0) as num;
    final reason = _aiSuggestion!['reason']?.toString() ?? '';
    final refined = _aiSuggestion!['refined']?.toString() ?? '';
    final correctiveAction = _aiSuggestion!['correctiveAction']?.toString() ?? '';
    final detectedLang = _aiSuggestion!['detectedLanguage']?.toString() ?? '';
    // Resolved here, not at accept time, so the card can only advertise fills
    // that will actually land. Promising a category and then applying '' would
    // make the reporter believe a field was set when it was not.
    final aiObsType = _canonicalObsType(_aiSuggestion!['category']?.toString() ?? '');
    final aiWsa = _canonicalWsa(_aiSuggestion!['wsaCause']?.toString() ?? '');
    final rawSeverity = _aiSuggestion!['severity']?.toString().trim().toUpperCase() ?? '';
    final aiSeverity = _severities.contains(rawSeverity) ? rawSeverity : '';
    // Built once. It is read three times below, and it is also what decides
    // whether there is anything to accept when the model returned a
    // classification but no rewording.
    final fills = _aiFillChips(sl, aiObsType, aiWsa, aiSeverity, correctiveAction);
    final canApply = refined.isNotEmpty || fills.isNotEmpty;

    // Indigo, not amber, green or red.
    //
    // Green read as "your report passed", which invited the reporter to treat
    // the AI as the authority on their own observation; red read as rejection.
    // Amber avoided both but collided with the app's own meaning for amber —
    // MEDIUM severity — so a card about a LOW hazard was framed in the colour of
    // a medium one, and it sat two fields away from a severity dropdown using
    // the same hue for something else entirely.
    //
    // Indigo (AppColors.accent) is the app's primary and carries no safety
    // meaning, so it reads as "the assistant is talking" rather than as a
    // verdict. It also matches the ✨ AI badge in _aiSetBadge, which is what
    // marks the fields this card fills — one colour now means one thing across
    // the whole interaction. The no-hazard path stays red: there the card is
    // reporting that it found nothing to work with.
    //
    // Both fills are contrast-checked against every foreground used below —
    // sl.accentText measures 5.24:1 on the dark fill and 4.89:1 on the light
    // one. Changing either hex means re-running tools/audit_contrast.py.
    final accent = hasHazard ? AppColors.accent : AppColors.red;
    final accentTx = hasHazard ? sl.accentText : sl.redText;
    final cardColor = hasHazard
        ? (sl.isDark ? const Color(0xFF1D2140) : const Color(0xFFEEF0FF))
        : (sl.isDark ? const Color(0xFF3A1B1B) : const Color(0xFFFFEBEE));

    Color confidenceColor;
    if (confidence >= 80) confidenceColor = AppColors.green;
    else if (confidence >= 50) confidenceColor = AppColors.amber;
    else confidenceColor = AppColors.red;
    final confidenceTx = confidence >= 80
        ? sl.greenText
        : (confidence >= 50 ? sl.amberText : sl.redText);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasHazard
                      ? Icons.auto_awesome_rounded
                      : Icons.help_outline_rounded,
                  size: 20, color: accentTx),
                const SizedBox(width: 8),
                Expanded(
                  // The observation type is lifted out of the sentence and onto
                  // a filled pill, because it is the one thing on this card that
                  // the reporter must actually agree or disagree with — it
                  // decides which register the observation is filed in, and
                  // "Unsafe Act" against "Unsafe Condition" is a one-word
                  // difference that reads past easily in a run of plain text.
                  child: hasHazard && aiObsType.isNotEmpty
                      ? Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            Text('AI reads this as:',
                                style: TextStyle(
                                    color: accentTx,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800)),
                            _obsTypePill(aiObsType),
                          ],
                        )
                      : Text(
                          hasHazard
                              ? 'AI has rephrased your description'
                              : 'Could not find a safety hazard in this text',
                          style: TextStyle(
                              color: accentTx,
                              fontSize: 13,
                              fontWeight: FontWeight.w800)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    // Near-white in light mode rather than a wash of the
                    // confidence colour over the card. The card fill moved from
                    // amber-cream (#FFF8E1) to indigo-lavender (#EEF0FF) in the
                    // recolour, and lavender is darker: the same 15% tint took
                    // greenText and redText from 4.52/4.55:1 down to 4.27:1,
                    // under AA. On white they measure above 5:1. This badge is
                    // the one the reporter reads to decide how much to trust the
                    // card, so it is not a place to lose legibility.
                    // audit_contrast.py cannot catch this — it scores tokens
                    // against the two global backgrounds, not a local card fill.
                    color: sl.isDark
                        ? confidenceColor.withOpacity(0.15)
                        : Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: confidenceColor.withOpacity(0.5)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.psychology_rounded, size: 12, color: confidenceTx),
                    const SizedBox(width: 4),
                    Text('${confidence.toInt()}%',
                      style: TextStyle(color: confidenceTx, fontSize: 12, fontWeight: FontWeight.w900)),
                  ]),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _dismissAiSuggestion,
                  child: Icon(Icons.close, size: 16, color: sl.text3),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'AI Confidence: ${confidence.toInt()}% — ${confidence >= 80 ? "High confidence" : confidence >= 50 ? "Moderate confidence" : "Low confidence"}${detectedLang.isNotEmpty ? ' • Language: $detectedLang' : ''}',
              style: TextStyle(color: sl.text3, fontSize: 10.5, fontWeight: FontWeight.w500)),
            // The reasoning, whichever way it went. On the no-hazard path this is
            // the only actionable thing in the card, so it is not optional there.
            if (reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(reason,
                style: TextStyle(color: sl.text2, fontSize: 11.5, height: 1.35)),
            ] else if (!hasHazard) ...[
              const SizedBox(height: 8),
              Text(
                'Describe what you saw, where it was, and what could have gone '
                'wrong — the mic works in Hindi too.',
                style: TextStyle(color: sl.text2, fontSize: 11.5, height: 1.35)),
            ],
            if (refined.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  // Inset panel: darker than the card on dark, lighter on light,
                  // so the AI's words are visibly a quotation rather than more
                  // card copy. Tinted with the card's own indigo instead of a
                  // neutral, which is what stopped it reading as a grey box
                  // dropped onto a coloured card.
                  color: sl.isDark
                      ? const Color(0xFF141733)
                      : Colors.white.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: accent.withOpacity(0.22)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.auto_awesome, size: 12, color: accentTx),
                      const SizedBox(width: 5),
                      Text('AI Refined Description:',
                        style: TextStyle(color: accentTx, fontSize: 10.5, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 4),
                    Text(refined,
                      style: TextStyle(color: sl.text1, fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
            ],
            if (correctiveAction.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: sl.isDark ? const Color(0xFF1A2A1A) : const Color(0xFFF1F8E9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.green.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.build_circle_outlined, size: 13, color: sl.greenText),
                      const SizedBox(width: 6),
                      Text('Suggested Corrective Action:',
                        style: TextStyle(color: sl.greenText, fontSize: 10.5, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 4),
                    Text(correctiveAction,
                      style: TextStyle(color: sl.text1, fontSize: 12, height: 1.4)),
                  ],
                ),
              ),
            ],
            // Names every field this will write, before it writes any of them.
            // Accepting used to change three dropdowns further up the form with
            // no warning, which on a long form is indistinguishable from the app
            // having filled them in by itself.
            if (fills.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(refined.isEmpty ? 'Accepting will set:' : 'Accepting will also set:',
                style: TextStyle(color: sl.text3, fontSize: 10.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: fills),
            ],
            const SizedBox(height: 12),
            // Keep / edit / reject. "Edit" is not a third opinion — it applies
            // the AI text and drops the caret into the field, because the common
            // case is that the rephrasing is nearly right and one clause is
            // wrong. Without it the reporter's only route to that is to accept,
            // then hunt for the field and tap it.
            //
            // Shown whenever there is anything to apply, which includes a
            // classification without a rewording: the chips above have already
            // promised those fills, so hiding the accept button would leave the
            // promise with no way to keep it.
            if (canApply)
              Row(
                children: [
                  Expanded(
                    child: _cardButton(
                      // Named for what the tap does. With no rewording on offer
                      // there is no "AI version" of the description to take,
                      // only the classification, and a button promising one
                      // would be describing something that isn't there.
                      label: refined.isEmpty ? 'Apply Fields' : 'Use AI Version',
                      icon: Icons.check_rounded,
                      filled: true,
                      color: AppColors.accent,
                      fg: Colors.white,
                      onTap: () => _acceptAiRefinement(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _cardButton(
                      label: refined.isEmpty ? 'Apply & Edit' : 'Edit It',
                      icon: Icons.edit_outlined,
                      filled: false,
                      color: AppColors.accent,
                      fg: sl.accentText,
                      onTap: () => _acceptAiRefinement(thenEdit: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _cardButton(
                      label: 'Keep Mine',
                      icon: Icons.person_outline_rounded,
                      filled: false,
                      color: sl.text3,
                      fg: sl.text2,
                      onTap: _dismissAiSuggestion,
                    ),
                  ),
                ],
              )
            else
              // Nothing to accept — the model found no hazard, or returned no
              // rephrasing. Dismissing is the only sensible action, and it is
              // labelled for what it does rather than as "Try Again": the text
              // stays exactly as typed and editing it re-runs the analysis.
              _cardButton(
                label: 'Edit My Description',
                icon: Icons.edit_outlined,
                filled: false,
                color: sl.text3,
                fg: sl.text2,
                onTap: () {
                  _dismissAiSuggestion();
                  _fnDescription.requestFocus();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// One chip per field the AI answer will populate, so the reporter can see
  /// the whole effect of "Use AI Version" before tapping it. Only fields that
  /// resolved to a real member of the admin's lists appear.
  /// Each chip is tinted by the MEANING of the field it fills, not decoratively:
  /// indigo for the classification, cyan for the WSA-13 cause, the severity's own
  /// signage colour for severity, green for the corrective action. The severity
  /// chip in particular has to agree with the colour the same value gets in the
  /// dropdown and on the dashboard — a chip promising "Severity: CRITICAL" in
  /// neutral grey while the field below turns red is the report contradicting
  /// itself in miniature.
  ///
  /// All foregrounds are `sl.*Text` getters, never the bare AppColors tokens:
  /// tools/audit_contrast.py fails `amber`/`green`/`red`/`accent` as TEXT in one
  /// theme or the other, and passes them as fills. The chip fill is kept near
  /// white in light mode rather than taking the card's lavender, because
  /// amberLight measures only 4.43:1 on that lavender and 5.02:1 on white.
  List<Widget> _aiFillChips(SL sl, String obsType, String wsa, String severity,
      String correctiveAction) {
    Widget chip(IconData ic, String label, Color tint, Color tx) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        // 0.10, not 0.16, on dark. The tint lightens the fill, and the WSA
        // chip's cyan is the weakest of the five foregrounds: at 0.16 it
        // measured 4.16:1 and missed AA, at 0.10 it is 4.58:1. Raising this
        // means re-measuring the cyan chip specifically — it fails first.
        color: sl.isDark
            ? tint.withOpacity(0.10)
            : Colors.white.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withOpacity(sl.isDark ? 0.45 : 0.40)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ic, size: 11, color: tx),
        const SizedBox(width: 4),
        Text(label,
          style: TextStyle(color: tx, fontSize: 10.5, fontWeight: FontWeight.w700)),
      ]),
    );

    // The severity chip borrows the plant's signage convention: red for the two
    // levels that stop work, amber for medium, green for low.
    //
    // An unrecognised label falls back to the card's own indigo, NOT to green.
    // Severity levels are admin-editable master data, and `severity` is only
    // checked for membership of that list — so a plant that renames HIGH to
    // "SEVERE" or "MAJOR" would otherwise get a green chip reading
    // "Severity: SEVERE", which is the exact self-contradiction this colouring
    // exists to prevent, and worse than no colour at all. Indigo carries no
    // safety meaning, so it reads as "unclassified" rather than as "safe".
    final sev = severity.trim().toUpperCase();
    final Color sevTint;
    final Color sevTx;
    if (sev == 'CRITICAL' || sev == 'HIGH') {
      sevTint = AppColors.red;
      sevTx = sl.redText;
    } else if (sev == 'MEDIUM') {
      sevTint = AppColors.amber;
      sevTx = sl.amberText;
    } else if (sev == 'LOW') {
      sevTint = AppColors.green;
      sevTx = sl.greenText;
    } else {
      sevTint = AppColors.accent;
      sevTx = sl.accentText;
    }

    return <Widget>[
      // Tinted per TYPE, not a flat indigo for every classification. The header
      // pill above already colours this exact value, and one value wearing two
      // colours inside one card is the same self-contradiction the severity chip
      // below exists to avoid — just quieter, and therefore easier to ship.
      if (obsType.isNotEmpty)
        chip(Icons.category_outlined, 'Type: $obsType',
            _obsTypeColor(obsType), _obsTypeInk(obsType, sl.isDark)),
      if (wsa.isNotEmpty)
        chip(Icons.account_tree_outlined, 'Category: $wsa',
            AppColors.cyan, sl.cyanText),
      if (severity.isNotEmpty)
        chip(Icons.speed_rounded, 'Severity: $severity', sevTint, sevTx),
      // Only advertised when it will actually be written: the existing rule is
      // that a corrective action already typed is never overwritten.
      if (correctiveAction.isNotEmpty && _immediateAction.text.trim().isEmpty)
        chip(Icons.build_circle_outlined, 'Corrective Action 1',
            AppColors.green, sl.greenText),
    ];
  }

  /// Shared button shape for the suggestion card's three choices.
  Widget _cardButton({
    required String label,
    required IconData icon,
    required bool filled,
    required Color color,
    required Color fg,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
          decoration: BoxDecoration(
            color: filled ? color : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: filled ? null : Border.all(color: color.withOpacity(0.55)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
            // The three labels have to survive a 320px screen in three columns.
            Flexible(
              child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      );

  /// ★ v32: Location field with GPS indicator + edit hint
  ///
  /// Three ways in, and the field says which one produced the current value:
  /// typed by hand, taken from the device GPS (tap the crosshair), or read from
  /// the photo's EXIF GPS tags when one is attached from the gallery. Manual
  /// text always wins — nothing here overwrites what the reporter typed.
  Widget _buildLocationField(SL sl) {
    final hasGpsLocation = _capturedLocation != null && _capturedLocation!.isValid;
    final isAutoFilled = hasGpsLocation &&
        _locSource.isNotEmpty &&
        _location.text.isNotEmpty &&
        _location.text != 'To be confirmed (edit if needed)';
    final hasErr = _errLocation != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _location,
          onChanged: (v) {
            // Typing makes the value the reporter's own, so the GPS/EXIF
            // provenance badge must stop claiming otherwise.
            // Read the fields directly rather than the captured `hasErr`, which
            // is only as fresh as the last build.
            if (_locSource.isNotEmpty || _errLocation != null) {
              setState(() { _locSource = ''; _errLocation = null; });
            }
            _onLocationChanged(v);
          },
          style: TextStyle(color: sl.text1, fontSize: 13),
          decoration: InputDecoration(
            label: _requiredLabel('Exact Location', sl, hasErr),
            errorText: _errLocation,
            errorStyle: TextStyle(color: sl.redText, fontSize: 10.5),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Icon(Icons.location_on_outlined, size: 18,
                color: hasErr
                    ? sl.redText
                    : (isAutoFilled ? sl.greenText : sl.accentText.withOpacity(0.7)))),
            prefixIconConstraints: const BoxConstraints(minWidth: 40),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              // Explicit "use my GPS" action. Device location was previously
              // only ever fetched as a side effect of attaching a photo, so a
              // reporter filing without one had no way to ask for it.
              IconButton(
                onPressed: _locating ? null : _useDeviceGps,
                tooltip: 'Use my current GPS location',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                icon: _locating
                    ? SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: sl.accentText))
                    : Icon(
                        isAutoFilled ? Icons.gps_fixed_rounded : Icons.my_location_rounded,
                        size: 17,
                        color: isAutoFilled ? sl.greenText : sl.accentText.withOpacity(0.8)),
              ),
              _micButton(_location),
            ]),
            filled: true,
            fillColor: hasErr
                ? AppColors.red.withOpacity(0.06)
                : (sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: isAutoFilled ? AppColors.green.withOpacity(0.4) : sl.border.withOpacity(0.5))),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.red, width: 1.6)),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.red, width: 2)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.accent, width: 2)),
          ),
        ),
        // The source is recorded at the point of filling, not guessed here. The
        // old version inferred EXIF from the string containing a comma, which
        // mislabels every reverse-geocoded street address.
        if (isAutoFilled)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 4),
            child: Text(
              _locSource == 'exif'
                  ? '📍 Read from the photo\'s own GPS tags — tap to edit if incorrect'
                  : '📍 Taken from this device\'s GPS — tap to edit if incorrect',
              style: TextStyle(color: sl.greenText.withOpacity(0.8), fontSize: 10.5, fontStyle: FontStyle.italic),
            ),
          ),
        if (!isAutoFilled && !hasErr)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 4),
            child: Text(
              'Type the location, or tap ⌖ to use GPS. A gallery photo\'s own GPS tags are used when present.',
              style: TextStyle(color: sl.text3, fontSize: 10.5, fontStyle: FontStyle.italic),
            ),
          ),
      ]),
    );
  }

  /// [errorText] non-null draws the field in red with the reason underneath.
  /// [required_] adds a red asterisk to the label so the reporter knows the
  /// field is mandatory BEFORE being refused at submit time.
  Widget _buildTextField(String label, TextEditingController controller, IconData icon, SL sl, {int maxLines = 1, TextInputType keyboardType = TextInputType.text, Widget? suffix, void Function(String)? onChanged, String? errorText, bool required_ = false, Widget? badge, FocusNode? focusNode}) {
    final hasErr = errorText != null;
    // The mic already occupies suffixIcon on the fields that have one, so the
    // "AI" chip has to share the slot rather than replace it — silently losing
    // the mic button is worse than a slightly crowded suffix.
    final Widget? suffixWidget = (suffix != null && badge != null)
        ? Row(mainAxisSize: MainAxisSize.min, children: [badge, suffix])
        : (suffix ?? badge);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        maxLines: maxLines,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: TextStyle(color: sl.text1, fontSize: 13),
        decoration: InputDecoration(
          label: required_ ? _requiredLabel(label, sl, hasErr) : null,
          labelText: required_ ? null : label,
          labelStyle: TextStyle(
            color: hasErr ? sl.redText : sl.text3, fontSize: 11.5),
          errorText: errorText,
          errorStyle: TextStyle(color: sl.redText, fontSize: 10.5),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 12, right: 8),
            child: Icon(icon, size: 18,
              color: hasErr ? sl.redText : sl.accentText.withOpacity(0.7))),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: suffixWidget,
          filled: true,
          fillColor: hasErr
              ? AppColors.red.withOpacity(0.06)
              : (sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC)),
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
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.red, width: 1.6)),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.red, width: 2)),
        ),
      ),
    );
  }

  /// Label with a trailing red asterisk for mandatory fields.
  Widget _requiredLabel(String label, SL sl, bool hasErr) => RichText(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: hasErr ? sl.redText : sl.text3,
        fontSize: 11.5,
        fontWeight: hasErr ? FontWeight.w700 : FontWeight.normal,
      ),
      children: [
        TextSpan(text: ' *',
          style: TextStyle(color: sl.redText, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ],
    ),
  );

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

  /// [requireChoice] makes an unset value render as a visible "Select…" hint
  /// instead of silently displaying items.first. Without it the fallback below
  /// shows the user a value the state does not hold — so a form that looks
  /// complete submits blank, or (worse) validation rejects a field the user can
  /// plainly see is filled in.
  Widget _buildDropdownField(String label, String value, List<String> items, ValueChanged<String?> onChanged, SL sl,
      {bool requireChoice = false, String? errorText, Widget? badge}) {
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
        value: items.contains(value)
            ? value
            : (requireChoice ? null : items.first),
        hint: requireChoice
            ? Text('Select…', style: TextStyle(
                color: errorText != null ? sl.redText : sl.text3, fontSize: 12))
            : null,
        items: items.map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 12)))).toList(),
        onChanged: onChanged,
        dropdownColor: sl.isDark ? const Color(0xFF252840) : Colors.white,
        style: TextStyle(color: sl.text1, fontSize: 12),
        icon: Icon(Icons.keyboard_arrow_down_rounded,
          color: errorText != null ? sl.redText : sl.text3),
        decoration: InputDecoration(
          label: requireChoice ? _requiredLabel(label, sl, errorText != null) : null,
          labelText: requireChoice ? null : label,
          labelStyle: TextStyle(
            color: errorText != null ? sl.redText : sl.text3, fontSize: 11.5),
          errorText: errorText,
          errorStyle: TextStyle(color: sl.redText, fontSize: 10.5),
          suffixIcon: badge,
          filled: true,
          fillColor: errorText != null
              ? AppColors.red.withOpacity(0.06)
              : (sl.isDark ? const Color(0xFF1C1F2E) : const Color(0xFFF8F9FC)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: sl.border.withOpacity(0.5))),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.red, width: 1.6)),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.red, width: 2)),
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
            controller: _formScroll,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ✅ Show listening banner when voice active
                _listeningBanner(sl),
                _guidanceBox(sl),
                _imageSection(sl),
                _detailsSection(sl),
                const SizedBox(height: 14),
                _descriptionSection(sl),
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
                  // PDF and Share stay available AFTER saving. They act on the
                  // record already persisted (_savedIncident), so neither one
                  // files a duplicate. Hiding them here meant the only way to
                  // get the PDF of a report you had just filed was to type the
                  // whole thing again.
                  if (_savedIncident != null) ...[
                    Row(children: [
                      Expanded(child: _postSaveBtn(
                        label: 'Download PDF',
                        icon: Icons.picture_as_pdf_rounded,
                        colors: const [Color(0xFF4F5BD5), Color(0xFF0EA5B5)],
                        onTap: _exportSavedPdf,
                        sl: sl,
                      )),
                      const SizedBox(width: 8),
                      Expanded(child: _postSaveBtn(
                        label: 'Share',
                        icon: Icons.share_rounded,
                        colors: const [Color(0xFFF59E0B), Color(0xFFF97316)],
                        onTap: _shareSavedReport,
                        sl: sl,
                      )),
                    ]),
                    const SizedBox(height: 10),
                  ],
                  // ★ New Report button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _postSaveBusy ? null : _resetForm,
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
