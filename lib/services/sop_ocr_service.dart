// lib/services/sop_ocr_service.dart
//
// Reads printed SOP / SMP pages photographed with the camera, and turns them
// into knowledge-base entries the AI chat can cite.
//
// TIERS, in order:
//   1. On-device ML Kit  — free, offline, ~50ms/page. Mobile only.
//   2. OpenRouter        — network, spends the free daily allowance. A CHAIN of
//                          models, not one: a single free model that is queued
//                          takes the whole tier down with it.
//   3. Nara (Mistral)    — separate quota. Never reachable on web (no CORS).
//   4. Gemini direct     — a paid-ish key the admin supplies. LAST, and not
//                          optional: it is the only tier left standing when the
//                          OpenRouter free allowance is spent, because that
//                          failure returns 429 (or a stall) on every free model
//                          at once. Both paths here omitted it until 2026-08-19,
//                          which is why a live web scan on safetylens.in showed
//                          four consecutive timeouts and then silently degraded
//                          to _mechanicalExtract. gemini_vision.dart had already
//                          learned this for the hazard chain; the SOP paths had
//                          not inherited it.
//
// This deliberately does NOT go through GeminiVision.analyseImageBytes. That
// method carries the hazard prompt, hazard-shaped JSON validation
// (`_isValidResult` would reject plain text outright), a result cache keyed for
// hazard analysis, and its own offline-fallback semantics. Pushing an OCR job
// through it would corrupt all four. What IS reused, on purpose, is the parts
// worth having exactly one copy of: key resolution
// (GeminiVision.openRouterKeys), the free-quota ledger
// (noteExternalFreeVisionRequest), the per-attempt timeout (kAttemptTimeout),
// and the tolerant JSON extractor (parseVisionResponse).
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ai_run_log.dart';
import 'gemini_direct_vision.dart';
import 'gemini_vision.dart';
import 'nara_vision.dart';
import 'sop_ocr_device.dart';

/// One page's recognition result.
class PageOcr {
  final int pageNo;
  final String text;

  /// Which tier produced [text]: 'device', 'openrouter', 'nara', 'gemini', or ''
  /// if none.
  final String engine;

  /// Empty when the page was read. Otherwise why it was not.
  final String error;

  /// Which quality gate sent this page to the AI tier, for tuning. Empty if the
  /// device tier was accepted or never ran.
  final String gate;

  const PageOcr({
    required this.pageNo,
    this.text = '',
    this.engine = '',
    this.error = '',
    this.gate = '',
  });

  bool get ok => error.isEmpty && text.trim().isNotEmpty;

  int get charCount => text.trim().length;
}

/// The structured form of a whole scanned document.
class SopExtract {
  final String sopNumber;
  final String title;
  final String revision;
  final String issueDate;
  final String department;
  final String scope;
  final List<String> ppe;
  final List<String> keyLimits;

  /// Each entry: {clauseNo, heading, text, page}.
  final List<Map<String, dynamic>> clauses;

  /// True when an AI structuring pass produced this. False means it was built
  /// mechanically from raw text because no provider was reachable — the caller
  /// must say so on screen rather than presenting it as a parsed document.
  final bool aiStructured;

  const SopExtract({
    this.sopNumber = '',
    this.title = '',
    this.revision = '',
    this.issueDate = '',
    this.department = '',
    this.scope = '',
    this.ppe = const [],
    this.keyLimits = const [],
    this.clauses = const [],
    this.aiStructured = false,
  });

  bool get isEmpty => clauses.isEmpty && scope.trim().isEmpty;

  /// Best available human label for the document.
  String get displayTitle {
    if (sopNumber.isNotEmpty && title.isNotEmpty) return '$sopNumber — $title';
    if (title.isNotEmpty) return title;
    if (sopNumber.isNotEmpty) return sopNumber;
    return 'Scanned document';
  }
}

class SopOcrService {
  // ═══════════════════════════════════════════════════════════════════════
  //  QUALITY GATES — when to escalate from the device tier to the AI tier
  //
  //  These are numbers, not a judgement call, because "the device OCR looked
  //  a bit thin" fires at random and cannot be tuned. Every escalation is
  //  attributed to exactly one gate and recorded on the PageOcr, so the
  //  thresholds can be adjusted against real plant documents instead of
  //  guessed at a second time.
  // ═══════════════════════════════════════════════════════════════════════

  /// A photographed A4 SOP page carries far more than this. Below it, the
  /// recogniser found a heading and gave up, or the page is blank.
  static const int minChars = 200;

  /// Recognisers fail into symbol soup rather than into silence, so a page that
  /// is mostly punctuation is a failure even when it is long.
  static const double minAlphaRatio = 0.5;

  /// Guards the case of many short fragments — table gridlines and stamps
  /// recognised as isolated characters.
  static const int minWords = 20;

  /// Cap on pages per scan. Each page is an OCR pass and, on the fallback path,
  /// one AI request out of a daily allowance of about fifty.
  static const int maxPages = 30;

  /// Per-page AI attempt timeout. Same budget as a hazard scan attempt.
  static Duration get attemptTimeout => GeminiVision.kAttemptTimeout;

  /// Per-attempt ceiling for a text-only call. Same 20s as everything else.
  ///
  /// This was 45s, on the reasoning that "the structuring pass reads a whole
  /// document, so it gets longer than a single page attempt". That reasoning
  /// confuses output size with queue time. gemini_vision.dart measured the real
  /// distribution on a live scan — 45,000ms spent on a model that never answered
  /// versus ~11,000ms for the one that did — and concluded that a free-tier model
  /// which has not answered in 20s is queued or stalled, not thinking. 45s here
  /// bought nothing and cost 25 extra seconds per dead key, twice over, because
  /// the safety pass is a second call through this same method.
  static Duration get textAttemptTimeout => GeminiVision.kAttemptTimeout;

  /// Whole-of-OpenRouter budget for one text call, mirroring `_kTier1Budget` in
  /// gemini_vision.dart. Without it, `models × keys` attempts multiply: three
  /// models against two keys at 20s each is two minutes of spinner before Gemini
  /// is even tried, and the tier that can actually answer is the one that gets
  /// starved.
  static const Duration textTierBudget = Duration(seconds: 40);

  /// Ceiling for the Gemini call. Longer than an OpenRouter attempt because this
  /// tier is not queue-limited and is the last one — there is nothing to save
  /// time for.
  static const Duration geminiTimeout = Duration(seconds: 30);

  /// Retained name, unchanged value, for any caller outside this file that reads
  /// it. Prefer [textAttemptTimeout]; this is now only an outer sanity bound.
  static const Duration summaryTimeout = Duration(seconds: 45);

  /// Vision model for OCR. The fast small model is the right pick: transcription
  /// needs no reasoning, and a reasoning model would emit thinking tokens out of
  /// the same output budget the page text has to fit into.
  static const String _ocrModel = 'nvidia/nemotron-nano-12b-v2-vl:free';

  /// Model chain for the TEXT-only passes (structuring, safety analysis).
  ///
  /// Three deliberate choices:
  ///
  /// * An instruct model leads, not [_ocrModel]. The text passes were pinned to
  ///   the vision model purely because it was the constant already in the file.
  ///   Both prompts ask for JSON over plain text, which is an instruct job.
  /// * It is a chain. One free model is a single point of failure, and the
  ///   observed failure mode is a stall rather than an error, so there is nothing
  ///   for the caller to react to.
  /// * `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` is deliberately
  ///   ABSENT. It is not a spare — it emits thinking tokens from the same 4096
  ///   `max_tokens` the JSON has to fit inside, so it returns truncated JSON, and
  ///   gemini_vision.dart demoted it for exactly that.
  static const List<String> _textModels = [
    'google/gemma-4-26b-a4b-it:free',
    'nvidia/nemotron-nano-12b-v2-vl:free',
    'dots-studio/dots-3-note-preview:free',
  ];

  static const String _orEndpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  // ═══════════════════════════════════════════════════════════════════════
  //  PROMPTS
  // ═══════════════════════════════════════════════════════════════════════

  /// Transcription prompt.
  ///
  /// The "do not invent" instruction is not boilerplate. A vision model asked to
  /// "read an SOP" will cheerfully produce plausible SOP language for a blurred
  /// paragraph, and invented safety text inside the knowledge base — which the
  /// prompt tells the model is authoritative for this plant — is the worst
  /// failure this feature can have. It is cheaper to lose a page and retake it.
  static const String ocrPrompt = '''
Transcribe ALL text visible in this photograph of a printed document page.

RULES:
1. Output the text VERBATIM. Do not summarise, correct, translate or rephrase.
2. Preserve the numbering exactly as printed (clause numbers like 4, 4.1, 6.2.3,
   and list markers a), b), i), ii)).
3. Preserve line structure. Keep each heading on its own line.
4. For a table, output one row per line with cells separated by " | ".
5. If a word or region is unreadable, write exactly [unreadable] in its place.
   NEVER guess at what it might say.
6. Do NOT add commentary, notes, headings or explanation of your own. Output the
   page's text and nothing else.
7. If the image contains no readable text at all, output exactly: [no text]
''';

  /// Structuring prompt. Returns JSON.
  static const String summaryPrompt = '''
The text below was read by OCR from a printed Standard Operating Procedure (SOP)
or Safe Method of Procedure (SMP) at a steel plant.

Return ONE JSON object, and nothing else, with exactly these keys:

{
  "sop_number": "the document/SOP number as printed, else \\"\\"",
  "title": "the document title, else \\"\\"",
  "revision": "revision number/letter as printed, else \\"\\"",
  "issue_date": "issue or effective date as printed, else \\"\\"",
  "department": "owning department/shop, else \\"\\"",
  "scope": "1-3 sentence scope or purpose, in the document's own words",
  "ppe": ["PPE items the document requires"],
  "key_limits": ["numeric limits, set points and thresholds, each with its unit"],
  "clauses": [
    {"clause_no": "6.2", "heading": "short heading", "text": "the clause text", "page": 4}
  ]
}

RULES:
1. Use ONLY what appears in the text. If a field is not present, use "" or [].
   Never infer a plausible SOP number, date or department.
2. Do not merge separate clauses, and do not split one clause into several.
3. Keep clause text close to the original wording. Light cleanup of obvious OCR
   damage in ordinary words is fine; NEVER "correct" a number, a unit, a
   clause number or a standard reference.
4. Copy every numeric limit into key_limits exactly as printed, with its unit.
5. Omit [unreadable] markers from the clause text, but do not fill the gap with
   invented words.
6. Output raw JSON only — no markdown fence, no preamble.
''';

  // ═══════════════════════════════════════════════════════════════════════
  //  PAGE OCR
  // ═══════════════════════════════════════════════════════════════════════

  /// Read one prepared page image. [jpegBytes] should already have been through
  /// `ImagePrep.prepareForOcr`.
  ///
  /// Never throws. A page that no tier can read comes back with `ok == false`
  /// and a populated [PageOcr.error], and the caller shows it as failed with a
  /// retake option. It must NOT be turned into placeholder text — see the
  /// offline-scan history in gemini_vision.dart for why generated stand-in
  /// content is never acceptable here.
  static Future<PageOcr> readPage(
    Uint8List jpegBytes, {
    required int pageNo,
    bool allowAi = true,
  }) async {
    final sw = Stopwatch()..start();

    // ── Tier 1: on-device ───────────────────────────────────────────────
    String deviceText = '';
    String gate = '';
    if (SopOcrDevice.isAvailable) {
      // Multi-script: Latin first, Devanagari only if the Latin pass came back
      // too thin to be a page of text. Hindi safety instructions are common on
      // plant notice boards and in bilingual SMPs, and the Latin model does not
      // fail on them — it returns a handful of stray marks, which would have
      // gone to the AI tier and spent a request on something the device can read
      // for free.
      deviceText = await SopOcrDevice.recogniseMultiScript(jpegBytes);
      gate = _failedGate(deviceText);
      if (gate.isEmpty) {
        _log(AiRunLog.typeSopOcr, AiRunLog.outcomeSuccess,
            provider: 'device', ms: sw.elapsedMilliseconds);
        return PageOcr(pageNo: pageNo, text: deviceText, engine: 'device');
      }
      print('SopOcr: page $pageNo device tier rejected by gate "$gate" '
          '(${deviceText.trim().length} chars) → AI tier');
    } else {
      gate = 'device_unavailable';
    }

    if (!allowAi) {
      // Offline / user opted out. Return the device text if there IS any, and
      // be explicit that it is below the quality bar rather than silently
      // treating it as a clean read.
      if (deviceText.trim().isNotEmpty) {
        return PageOcr(
          pageNo: pageNo,
          text: deviceText,
          engine: 'device',
          gate: gate,
        );
      }
      _log(AiRunLog.typeSopOcr, AiRunLog.outcomeFailed,
          reason: AiRunLog.reasonNoInternet, ms: sw.elapsedMilliseconds);
      return PageOcr(
        pageNo: pageNo,
        error: SopOcrDevice.isAvailable
            ? 'No text found, and the AI reader needs a connection.'
            : 'Reading this page needs a connection.',
        gate: gate,
      );
    }

    // ── Tier 2: OpenRouter ─────────────────────────────────────────────
    final keys = await GeminiVision.openRouterKeys();
    for (final key in keys) {
      final text = await _callOpenRouterOcr(jpegBytes, key);
      if (text != null && _failedGate(text).isEmpty) {
        _log(AiRunLog.typeSopOcr, AiRunLog.outcomeSuccess,
            provider: 'openrouter', model: _ocrModel, ms: sw.elapsedMilliseconds);
        return PageOcr(
            pageNo: pageNo, text: text, engine: 'openrouter', gate: gate);
      }
    }

    // ── Tier 3: Nara ───────────────────────────────────────────────────
    final naraText = await _callNaraOcr(jpegBytes);
    if (naraText != null && _failedGate(naraText).isEmpty) {
      _log(AiRunLog.typeSopOcr, AiRunLog.outcomeSuccess,
          provider: 'nara', ms: sw.elapsedMilliseconds);
      return PageOcr(pageNo: pageNo, text: naraText, engine: 'nara', gate: gate);
    }

    // ── Tier 4: Gemini direct ──────────────────────────────────────────
    //
    // The tier this path was missing. On web tiers 1 and 3 are both structurally
    // unavailable — no ML Kit in a browser, and Nara is CORS-blocked — which left
    // OpenRouter as the sole reader, so one queued free model meant no reader at
    // all. Same conclusion gemini_vision.dart reached for hazard scans, where the
    // comment reads that a configured Gemini key "is the only path that still
    // analyses the image" once the free cap is hit.
    final geminiText = await _callGeminiOcr(jpegBytes);
    if (geminiText != null && _failedGate(geminiText).isEmpty) {
      _log(AiRunLog.typeSopOcr, AiRunLog.outcomeSuccess,
          provider: 'gemini', ms: sw.elapsedMilliseconds);
      return PageOcr(
          pageNo: pageNo, text: geminiText, engine: 'gemini', gate: gate);
    }

    // ── Everything failed ──────────────────────────────────────────────
    // Fall back to the device text ONLY if it exists, flagged by its gate so
    // the review screen can warn about it. Otherwise report failure honestly.
    if (deviceText.trim().isNotEmpty) {
      _log(AiRunLog.typeSopOcr, AiRunLog.outcomeSuccess,
          provider: 'device', ms: sw.elapsedMilliseconds);
      return PageOcr(
          pageNo: pageNo, text: deviceText, engine: 'device', gate: gate);
    }
    _log(AiRunLog.typeSopOcr, AiRunLog.outcomeFailed,
        reason: AiRunLog.reasonExhausted, ms: sw.elapsedMilliseconds);
    return PageOcr(
      pageNo: pageNo,
      error: keys.isEmpty && !SopOcrDevice.isAvailable
          ? 'No text reader available. Ask the admin to add an AI key.'
          : 'Could not read this page. Retake it with more light, straight on, '
              'and filling the frame.',
      gate: gate,
    );
  }

  /// Which quality gate this text fails, or '' if it passes.
  static String _failedGate(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'empty';
    // The transcription prompt's own "nothing here" answer.
    if (t.toLowerCase() == '[no text]') return 'empty';
    if (t.length < minChars) return 'too_short';

    int alpha = 0;
    int nonSpace = 0;
    for (final c in t.codeUnits) {
      final isSpace = c == 32 || c == 10 || c == 13 || c == 9;
      if (isSpace) continue;
      nonSpace++;
      final isAz = (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
      final isDigit = c >= 48 && c <= 57;
      if (isAz || isDigit) alpha++;
    }
    if (nonSpace == 0) return 'empty';
    if (alpha / nonSpace < minAlphaRatio) return 'symbol_soup';

    final words = t.split(RegExp(r'\s+')).where((w) => w.length > 1).length;
    if (words < minWords) return 'too_few_words';
    return '';
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  PROVIDER CALLS
  // ═══════════════════════════════════════════════════════════════════════

  /// A short, single-line excerpt of an error response body, for logging.
  ///
  /// Exists because a bare `HTTP 400` cost real debugging time: it looks the
  /// same whether the model slug is wrong, `max_tokens` is over the model's
  /// ceiling, or a content part is malformed — three problems with three
  /// different fixes, and the provider names the actual one in the body.
  ///
  /// Capped and newline-collapsed on purpose. An error body can echo the whole
  /// request back, and this request carries a base64 page image; unfiltered,
  /// one failed scan would push megabytes of data URL through the console and
  /// bury every other line in the log.
  static String _briefBody(String body) {
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '(empty body)';
    return flat.length <= 300 ? flat : '${flat.substring(0, 300)}…';
  }

  static Future<String?> _callOpenRouterOcr(
      Uint8List bytes, String apiKey) async {
    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    try {
      final response = await http
          .post(
            Uri.parse(_orEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
              'HTTP-Referer': 'https://abhibond1986.github.io/SL-22061984/',
              'X-Title': 'SAIL Safety Lens',
            },
            body: jsonEncode({
              'model': _ocrModel,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': ocrPrompt},
                    {'type': 'image_url', 'image_url': {'url': dataUrl}},
                  ]
                }
              ],
              // 4096, matching the hazard-scan call in gemini_vision.dart.
              //
              // This was 8192 — "a dense A4 page can exceed 2000 tokens, and a
              // truncated transcription silently loses the bottom of the page" —
              // and every request came back HTTP 400. The reasoning was fine and
              // the number was still wrong: 8192 is above this model's
              // max_completion_tokens, and OpenRouter rejects the request rather
              // than clamping it. The hazard path has been sending 4096 to the
              // same model for months, which is the evidence that matters.
              //
              // If a long page really is being truncated, the fix is to split
              // the page, not to raise this: the ceiling is the provider's.
              'max_tokens': 4096,
              // Transcription must not vary run to run.
              'temperature': 0,
              'top_p': 1,
              'seed': 42,
            }),
          )
          .timeout(attemptTimeout);

      // Ledger before parsing — a malformed 200 still spent the request.
      if (response.statusCode == 200) {
        await GeminiVision.noteExternalFreeVisionRequest(served: true);
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices == null || choices.isEmpty) return null;
        return choices[0]['message']?['content']?.toString();
      }
      if (response.statusCode == 429) {
        await GeminiVision.noteExternalFreeVisionRequest(served: false);
        print('SopOcr: OpenRouter 429 — free allowance or throttle');
        return null;
      }
      // Log the BODY, not just the status. A bare 'HTTP 400' is what this
      // printed before, and it is indistinguishable between a bad model slug, an
      // over-limit max_tokens and a malformed content part — all of which need
      // different fixes. OpenRouter puts the actual reason in the body. Capped
      // because an error body can carry the echoed request back.
      print('SopOcr: OpenRouter HTTP ${response.statusCode} — '
          '${_briefBody(response.body)}');
      return null;
    } on TimeoutException {
      print('SopOcr: OpenRouter timed out after ${attemptTimeout.inSeconds}s');
      return null;
    } catch (e) {
      print('SopOcr: OpenRouter failed — $e');
      return null;
    }
  }

  static Future<String?> _callNaraOcr(Uint8List bytes) async {
    try {
      // isDirectCallUsableHere, not isConfigured and NOT isUsableHere: this posts
      // to NaraVision.endpoint itself, and on web that is CORS-blocked, so the
      // attempt can only spend attemptTimeout to arrive at the same failure.
      //
      // isUsableHere would be WRONG here as of 2026-08-19. It now returns true on
      // web, because the HAZARD path reaches Nara through the Apps Script proxy —
      // this OCR call does not, so it must ask the narrower question. Switch to
      // isUsableHere only if this call is moved onto the proxy too.
      if (!await NaraVision.isDirectCallUsableHere) return null;
      final apiKey = (await NaraVision.getApiKey()).trim();
      final model = await NaraVision.getModel();
      final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      final response = await http
          .post(
            Uri.parse(NaraVision.endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': ocrPrompt},
                    {'type': 'image_url', 'image_url': {'url': dataUrl}},
                  ]
                }
              ],
              // 4096 for the same reason as the OpenRouter call above: this is a
              // per-model ceiling, not a per-provider one, and asking above it
              // gets the request rejected rather than clamped.
              'max_tokens': 4096,
              'temperature': 0,
              'top_p': 1,
              'seed': 42,
            }),
          )
          .timeout(attemptTimeout);
      if (response.statusCode != 200) {
        print('SopOcr: Nara HTTP ${response.statusCode} — '
            '${_briefBody(response.body)}');
        return null;
      }
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final choices = data['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;
      return choices[0]['message']?['content']?.toString();
    } on TimeoutException {
      print('SopOcr: Nara timed out');
      return null;
    } catch (e) {
      print('SopOcr: Nara failed — $e');
      return null;
    }
  }

  /// Gemini direct, used as a transcriber.
  ///
  /// Sends [ocrPrompt] with the page image and returns plain text. Note there is
  /// no `responseMimeType` here, unlike the text call: a transcription is not
  /// JSON, and asking Gemini for JSON would make it wrap the page in a structure
  /// this caller would then have to unwrap — an extra parse that can fail on a
  /// document containing quotes or braces, which printed SOPs do.
  ///
  /// Uses only the public surface of [GeminiDirectVision] and deliberately does
  /// NOT call its `analyzeImage`, which carries the hazard prompt and hazard JSON
  /// validation; see this file's header.
  static Future<String?> _callGeminiOcr(Uint8List bytes) async {
    try {
      if (!await GeminiDirectVision.isConfigured) return null;
      final apiKey = (await GeminiDirectVision.getApiKey()).trim();
      if (apiKey.isEmpty) return null;
      final model = await GeminiDirectVision.getModel();

      final r = await http
          .post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/'
                'models/$model:generateContent?key=$apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': ocrPrompt},
                    {
                      'inline_data': {
                        'mime_type': 'image/jpeg',
                        'data': base64Encode(bytes),
                      }
                    },
                  ]
                }
              ],
              'generationConfig': {
                'temperature': 0,
                'topP': 1,
                'maxOutputTokens': 8192,
              },
            }),
          )
          .timeout(geminiTimeout);
      if (r.statusCode != 200) {
        print('SopOcr: Gemini OCR HTTP ${r.statusCode} — '
            '${_briefBody(r.body)}');
        return null;
      }
      final data = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return null;
      final parts = candidates[0]['content']?['parts'] as List?;
      if (parts == null || parts.isEmpty) return null;
      final text = parts[0]['text']?.toString();
      if (text == null || text.trim().isEmpty) return null;
      print('SopOcr: page read by Gemini ($model)');
      return text;
    } on TimeoutException {
      print('SopOcr: Gemini OCR timed out after ${geminiTimeout.inSeconds}s');
      return null;
    } catch (e) {
      print('SopOcr: Gemini OCR failed — $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  STRUCTURING PASS
  // ═══════════════════════════════════════════════════════════════════════

  /// Turn the concatenated page text into a [SopExtract].
  ///
  /// Returns an extract with `aiStructured == false` when no provider could be
  /// reached. That case is NOT an error — the raw text is already saved and the
  /// document can be re-structured later — but the caller must label it, because
  /// a mechanically split document has no clause numbers and no citations.
  static Future<SopExtract> structure(
    List<PageOcr> pages, {
    String fallbackTitle = '',
  }) async {
    final usable = pages.where((p) => p.ok).toList();
    if (usable.isEmpty) return const SopExtract();

    final sw = Stopwatch()..start();
    final joined = usable
        .map((p) => '--- PAGE ${p.pageNo} ---\n${p.text.trim()}')
        .join('\n\n');

    // A very long document would blow the model's context. Truncate the INPUT
    // rather than failing: the raw text is stored in full regardless, so a
    // partial structuring loses citations for the tail, not the content.
    const maxInputChars = 60000;
    final input = joined.length > maxInputChars
        ? '${joined.substring(0, maxInputChars)}\n\n[document truncated]'
        : joined;

    final raw = await _callTextModel('$summaryPrompt\n\nDOCUMENT TEXT:\n$input');
    if (raw == null) {
      _log(AiRunLog.typeSopSummary, AiRunLog.outcomeFailed,
          reason: AiRunLog.reasonExhausted, ms: sw.elapsedMilliseconds);
      return _mechanicalExtract(usable, fallbackTitle: fallbackTitle);
    }

    // Reuse the tolerant extractor — models wrap JSON in fences and prose, and
    // a bare jsonDecode would reject most real responses.
    final parsed = GeminiVision.parseVisionResponse(raw);
    if (parsed == null) {
      _log(AiRunLog.typeSopSummary, AiRunLog.outcomeFailed,
          reason: AiRunLog.reasonEmptyResult, ms: sw.elapsedMilliseconds);
      return _mechanicalExtract(usable, fallbackTitle: fallbackTitle);
    }

    final clauses = <Map<String, dynamic>>[];
    final rawClauses = parsed['clauses'];
    if (rawClauses is List) {
      for (final c in rawClauses) {
        if (c is! Map) continue;
        final text = c['text']?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        clauses.add({
          'clauseNo': c['clause_no']?.toString().trim() ?? '',
          'heading':  c['heading']?.toString().trim() ?? '',
          'text':     text,
          'page':     int.tryParse(c['page']?.toString() ?? '') ?? 0,
        });
      }
    }

    _log(AiRunLog.typeSopSummary, AiRunLog.outcomeSuccess,
        ms: sw.elapsedMilliseconds);

    return SopExtract(
      sopNumber:  parsed['sop_number']?.toString().trim() ?? '',
      title:      parsed['title']?.toString().trim().isNotEmpty == true
          ? parsed['title'].toString().trim()
          : fallbackTitle,
      revision:   parsed['revision']?.toString().trim() ?? '',
      issueDate:  parsed['issue_date']?.toString().trim() ?? '',
      department: parsed['department']?.toString().trim() ?? '',
      scope:      parsed['scope']?.toString().trim() ?? '',
      ppe:        _stringList(parsed['ppe']),
      keyLimits:  _stringList(parsed['key_limits']),
      clauses:    clauses,
      aiStructured: true,
    );
  }

  static List<String> _stringList(dynamic v) {
    if (v is! List) return const [];
    return v
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// No-AI fallback: one "clause" per page, no numbers, nothing invented.
  ///
  /// Page-sized units rather than blind character slices, because a page break
  /// is a real boundary in the document whereas a 2500-character cut lands
  /// mid-sentence and mid-procedure.
  static SopExtract _mechanicalExtract(List<PageOcr> pages,
      {String fallbackTitle = ''}) {
    return SopExtract(
      title: fallbackTitle,
      clauses: [
        for (final p in pages)
          {
            'clauseNo': '',
            'heading':  'Page ${p.pageNo}',
            'text':     p.text.trim(),
            'page':     p.pageNo,
          }
      ],
      aiStructured: false,
    );
  }

  /// Public text-only model call, for other SOP passes to reuse.
  ///
  /// Exists so [SopSafetyAnalysis] does not stand up a second LLM integration
  /// for the same job: this already carries the four-tier provider order, the key
  /// ledger, the per-attempt and tier budgets, the 4096-token ceiling that
  /// OpenRouter rejects above, and the non-200 logging that took a live console
  /// session to find. A parallel copy would drift from all five.
  ///
  /// Worth knowing when calling this twice in one flow, as the scan screen does
  /// (structuring, then safety): the tiers are sequential, so two calls against a
  /// dead OpenRouter cost two budgets end to end. That is survivable at 40s each
  /// and was not at 45s per key per call, which is what the live console showed.
  ///
  /// Deliberately a thin wrapper rather than making [_callTextModel] public:
  /// keeping the private method as the single implementation means the OCR and
  /// analysis paths cannot diverge, and the doc comment above is the contract
  /// callers actually need.
  ///
  /// Returns null when every provider failed. Callers must treat that as
  /// "no analysis available" and must NOT substitute generated content — a
  /// fabricated safety requirement is worse than a missing one.
  static Future<String?> askTextModel(String prompt) => _callTextModel(prompt);

  /// Text-only model call for the structuring pass. Same provider order as OCR.
  ///
  /// Returns null only when all four tiers are exhausted. Every tier logs why it
  /// declined, because the caller's fallback ([_mechanicalExtract]) produces a
  /// plausible-looking result and so cannot be told apart from success on screen.
  static Future<String?> _callTextModel(String prompt) async {
    final sw = Stopwatch()..start();
    final body = {
      'model': _textModels.first,
      'messages': [
        {'role': 'user', 'content': prompt}
      ],
      // 4096. This map is shared by the OpenRouter and Nara requests below, so
      // the 8192 that was here failed the structuring pass on BOTH providers —
      // the same HTTP 400 the OCR call was getting, one step later in the flow.
      // It would have shown up as "AI could not structure this document" with a
      // mechanical page-per-clause fallback, i.e. as a quality problem rather
      // than as the provider error it is.
      'max_tokens': 4096,
      'temperature': 0,
      'top_p': 1,
      'seed': 42,
    };

    // ── Tier 1: OpenRouter, every model against every key ───────────────
    //
    // Model outer, key inner: a stalled model stalls for all keys, whereas a
    // rate-limited key still has other models available to it. Trying key-outer
    // would spend the whole budget re-confirming that model one is stuck.
    final keys = await GeminiVision.openRouterKeys();
    for (final model in _textModels) {
      for (final key in keys) {
        if (sw.elapsed >= textTierBudget) {
          print('SopOcr: summary OpenRouter budget spent after '
              '${sw.elapsedMilliseconds}ms → next tier');
          break;
        }
        try {
          final r = await http
              .post(
                Uri.parse(_orEndpoint),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $key',
                  'HTTP-Referer': 'https://abhibond1986.github.io/SL-22061984/',
                  'X-Title': 'SAIL Safety Lens',
                },
                body: jsonEncode({...body, 'model': model}),
              )
              .timeout(textAttemptTimeout);
          if (r.statusCode == 200) {
            await GeminiVision.noteExternalFreeVisionRequest(served: true);
            final data =
                jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
            final choices = data['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final content = choices[0]['message']?['content']?.toString();
              // An empty 200 is a real outcome, not a success: it is what a
              // model returns when the whole token budget went on thinking.
              // Returning it would hand the caller "" to parse as JSON.
              if (content != null && content.trim().isNotEmpty) return content;
              print('SopOcr: summary $model returned an empty 200 → next model');
            }
          } else if (r.statusCode == 429) {
            await GeminiVision.noteExternalFreeVisionRequest(served: false);
            // Name the model. "429" alone reads as "we are out of allowance",
            // when it can equally be this one model being throttled.
            print('SopOcr: summary $model 429 — throttled or allowance spent');
          } else {
            // Was silent. A failed structuring pass degrades to
            // _mechanicalExtract, which produces a plausible-looking result, so
            // without this line the only symptom is "the AI stopped finding
            // clause numbers".
            print('SopOcr: summary OpenRouter HTTP ${r.statusCode} on $model — '
                '${_briefBody(r.body)}');
          }
        } on TimeoutException {
          print('SopOcr: summary $model timed out after '
              '${textAttemptTimeout.inSeconds}s → next');
        } catch (e) {
          print('SopOcr: summary via OpenRouter ($model) failed — $e');
        }
      }
    }

    // ── Tier 2: Nara ────────────────────────────────────────────────────
    //
    // Wrapped so an unusable Nara falls THROUGH to Gemini. This used to
    // `return null` on `!isUsableHere`, which on web — where Nara is always
    // unusable, being CORS-blocked — meant the branch below could never run at
    // all. That single `return` is most of the reason a web scan had no working
    // provider.
    final naraText = await _callNaraText(body);
    if (naraText != null) return naraText;

    // ── Tier 3: Gemini direct ───────────────────────────────────────────
    final geminiText = await _callGeminiText(prompt);
    if (geminiText != null) return geminiText;

    print('SopOcr: summary — all providers exhausted after '
        '${sw.elapsedMilliseconds}ms');
    return null;
  }

  /// Nara text call. Returns null for "not available here" and for any failure;
  /// the two are equivalent to the caller, which has another tier either way.
  static Future<String?> _callNaraText(Map<String, dynamic> body) async {
    try {
      // Direct-call test, for the same reason as _callNaraOcr above: this posts
      // to NaraVision.endpoint, which no browser can reach. See
      // NaraVision.isDirectCallUsableHere.
      if (!await NaraVision.isDirectCallUsableHere) return null;
      final apiKey = (await NaraVision.getApiKey()).trim();
      final model = await NaraVision.getModel();
      final r = await http
          .post(
            Uri.parse(NaraVision.endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({...body, 'model': model}),
          )
          .timeout(textAttemptTimeout);
      if (r.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final content = choices[0]['message']?['content']?.toString();
          if (content != null && content.trim().isNotEmpty) return content;
        }
      } else {
        print('SopOcr: summary Nara HTTP ${r.statusCode} — '
            '${_briefBody(r.body)}');
      }
    } on TimeoutException {
      print('SopOcr: summary Nara timed out');
    } catch (e) {
      print('SopOcr: summary via Nara failed — $e');
    }
    return null;
  }

  /// Last tier: Gemini direct, text only.
  ///
  /// Built here rather than added to [GeminiDirectVision] on purpose. That class
  /// belongs to the hazard/near-miss path — its `analyzeImage` carries the hazard
  /// prompt and hazard-shaped response parsing, and this file's own header
  /// explains why an OCR job must not be pushed through hazard machinery. So only
  /// the three pieces that are genuinely shared are reused, all already public:
  /// `isConfigured`, `getApiKey()` and `getModel()` — the last of which
  /// transparently rewrites retired model IDs, which is precisely the logic worth
  /// not copying.
  ///
  /// `responseMimeType: application/json` suits both callers: the structuring
  /// prompt and the safety prompt each demand a JSON object. If a future caller
  /// wants prose, that is the moment to add a parameter — not before.
  static Future<String?> _callGeminiText(String prompt) async {
    try {
      if (!await GeminiDirectVision.isConfigured) {
        print('SopOcr: summary — no Gemini key configured, nothing left to try');
        return null;
      }
      final apiKey = (await GeminiDirectVision.getApiKey()).trim();
      if (apiKey.isEmpty) return null;

      // The admin's selected model first, then the package default, deduped. Two
      // attempts, not the whole fallback chain: this tier runs after the budget
      // above is already spent, and the user has been watching a spinner for
      // most of a minute by the time it starts.
      final selected = await GeminiDirectVision.getModel();
      final models = <String>[selected];
      if (selected != GeminiDirectVision.defaultModel) {
        models.add(GeminiDirectVision.defaultModel);
      }

      for (final model in models) {
        try {
          final r = await http
              .post(
                Uri.parse('https://generativelanguage.googleapis.com/v1beta/'
                    'models/$model:generateContent?key=$apiKey'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'contents': [
                    {
                      'parts': [
                        {'text': prompt}
                      ]
                    }
                  ],
                  'generationConfig': {
                    'temperature': 0,
                    'topP': 1,
                    // Gemini's own ceiling, and it is NOT the 4096 that
                    // OpenRouter enforces per model. Different provider, so do
                    // not "make it consistent" — the 4096 above exists because
                    // OpenRouter rejects rather than clamps.
                    'maxOutputTokens': 8192,
                    'responseMimeType': 'application/json',
                  },
                }),
              )
              .timeout(geminiTimeout);
          if (r.statusCode != 200) {
            print('SopOcr: summary Gemini HTTP ${r.statusCode} on $model — '
                '${_briefBody(r.body)}');
            continue;
          }
          final data =
              jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
          final candidates = data['candidates'] as List?;
          if (candidates == null || candidates.isEmpty) {
            // A 200 with no candidates is a safety block, and the reason is in
            // promptFeedback. Worth printing: an SOP about gas lines or lifting
            // can trip a content filter, and that looks identical to a stall.
            print('SopOcr: summary Gemini returned no candidates — '
                '${_briefBody(jsonEncode(data['promptFeedback'] ?? {}))}');
            continue;
          }
          final parts =
              candidates[0]['content']?['parts'] as List?;
          if (parts == null || parts.isEmpty) continue;
          final text = parts[0]['text']?.toString();
          if (text != null && text.trim().isNotEmpty) {
            print('SopOcr: summary served by Gemini ($model)');
            return text;
          }
        } on TimeoutException {
          print('SopOcr: summary Gemini timed out on $model after '
              '${geminiTimeout.inSeconds}s');
        }
      }
    } catch (e) {
      print('SopOcr: summary via Gemini failed — $e');
    }
    return null;
  }

  static void _log(
    String type,
    String outcome, {
    String reason = '',
    String provider = '',
    String model = '',
    int ms = 0,
  }) {
    // Fire and forget — telemetry must never delay or break a scan.
    AiRunLog.record(
      runType: type,
      outcome: outcome,
      failReason: reason,
      provider: provider,
      model: model,
      durationMs: ms,
    );
  }
}
