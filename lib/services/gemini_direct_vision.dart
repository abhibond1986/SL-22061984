// lib/services/gemini_direct_vision.dart
// ★ v28: Direct Gemini Vision API for hazard image analysis
//
// Free tier: 15 requests/minute, 1M tokens/day, image input via base64,
// no billing required — just an API key from https://aistudio.google.com/apikey
//
// This runs as TIER 2 of the vision chain in gemini_vision.dart, on a quota
// separate from OpenRouter's, so it still works when OpenRouter returns 429.
//
// ⚠ MODEL IDS EXPIRE. Google retires models on published shutdown dates, after
// which the endpoint returns HTTP 404 "This model is no longer available" and
// analysis fails silently. On 2026-08-15 this file still pointed at
// gemini-2.0-flash and gemini-2.0-flash-lite, both shut down 2026-06-01, so
// every direct-Gemini scan 404'd. Before editing the chain below, check
// https://ai.google.dev/gemini-api/docs/deprecations for shutdown dates and add
// any newly-retired ID to [_retiredModels] so saved user preferences migrate.

import 'dart:convert';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_master_data.dart';
// For the shared observer-note prompt block. gemini_vision.dart imports this
// file in turn; Dart allows mutual imports between libraries and the pair
// nara_vision.dart / gemini_vision.dart already relies on that.
import 'gemini_vision.dart';

class GeminiDirectVision {
  static const String _kApiKey = 'gemini_vision_api_key';
  static const String _kModel = 'gemini_vision_model';
  /// Default Tier 2 model when no admin selection is saved.
  ///
  /// Flash-Lite, not Flash, since 2026-08-17. Reordering [_modelFallbackChain]
  /// alone would NOT have taken effect: [analyzeImage] puts the admin's
  /// `selected` model at the head of the attempt list, and `selected` falls back
  /// to this constant — so with 3.6-flash here, Flash still went first on every
  /// device that had never touched the admin dropdown, and the reordered chain
  /// below only applied from the second attempt onward.
  ///
  /// ⚠ Devices with a model ALREADY saved in SharedPreferences keep using it —
  /// see [_retiredModels] for why changing this constant does not reach them.
  /// An admin who previously pinned 3.6 Flash must change it in
  /// Admin → System Health to pick up this new default.
  static const String defaultModel = 'gemini-3.1-flash-lite';

  /// Retired model IDs → their documented replacement.
  ///
  /// Why this map is essential and not just cosmetic: the selected model is
  /// persisted in SharedPreferences on each device. Changing [defaultModel]
  /// alone does NOT help anyone who already has a retired ID saved — their
  /// browser keeps sending the dead model forever. [getModel] rewrites through
  /// this map so existing installs self-heal on the next scan.
  static const Map<String, String> _retiredModels = {
    'gemini-2.0-flash': 'gemini-3.6-flash',
    'gemini-2.0-flash-001': 'gemini-3.6-flash',
    'gemini-2.0-flash-lite': 'gemini-3.1-flash-lite',
    'gemini-2.0-flash-lite-001': 'gemini-3.1-flash-lite',
    'gemini-1.5-flash': 'gemini-3.6-flash',
    'gemini-1.5-pro': 'gemini-2.5-pro',
    'gemini-2.5-flash-preview-09-25': 'gemini-3.6-flash',
  };

  static SharedPreferences? _prefs;

  static Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Check if Gemini API key is configured
  static Future<bool> get isConfigured async {
    await _ensurePrefs();
    final key = _prefs!.getString(_kApiKey) ?? '';
    return key.isNotEmpty && key.length > 20;
  }

  /// Get stored API key
  static Future<String> getApiKey() async {
    await _ensurePrefs();
    return _prefs!.getString(_kApiKey) ?? '';
  }

  /// Save API key (from Admin panel)
  static Future<void> setApiKey(String key) async {
    await _ensurePrefs();
    await _prefs!.setString(_kApiKey, key.trim());
  }

  /// Get current model, transparently upgrading a retired saved ID.
  ///
  /// The rewrite is persisted so the admin panel dropdown also stops showing a
  /// dead model, and so this costs one write rather than one lookup per scan.
  static Future<String> getModel() async {
    await _ensurePrefs();
    final saved = _prefs!.getString(_kModel);
    if (saved == null || saved.isEmpty) return defaultModel;
    final replacement = _retiredModels[saved];
    if (replacement != null) {
      print('GeminiDirectVision: ⚙ Saved model "$saved" was retired by Google '
          '— migrating to "$replacement"');
      await _prefs!.setString(_kModel, replacement);
      return replacement;
    }
    return saved;
  }

  /// Set model preference
  static Future<void> setModel(String model) async {
    await _ensurePrefs();
    await _prefs!.setString(_kModel, model);
  }

  /// Models offered in the Admin panel dropdown.
  /// All are current, non-preview, and accept image input. Verified against
  /// https://ai.google.dev/gemini-api/docs/models on 2026-08-15.
  // Order mirrors [_modelFallbackChain] and [defaultModel] — Flash-Lite first.
  // Keep all three in step; a dropdown that disagrees with the runtime chain is
  // how an admin ends up "selecting" a model that is not actually tried first.
  static const List<Map<String, String>> availableModels = [
    {'id': 'gemini-3.1-flash-lite', 'name': 'Gemini 3.1 Flash-Lite (Recommended — highest quota, fastest)'},
    {'id': 'gemini-3.6-flash',      'name': 'Gemini 3.6 Flash (fast)'},
    {'id': 'gemini-3.7-flash',      'name': 'Gemini 3.7 Flash (Newest)'},
    {'id': 'gemini-2.5-flash',      'name': 'Gemini 2.5 Flash (Older, still supported)'},
    {'id': 'gemini-2.5-pro',        'name': 'Gemini 2.5 Pro (Most accurate, low quota)'},
  ];

  /// Tried in order after the admin's selected model, so a per-model rate limit
  /// or an unexpected retirement does not end the scan. Each entry is a distinct
  /// model with its own quota bucket.
  // ORDER = HIGHEST QUOTA + LOWEST LATENCY FIRST (set 2026-08-17 on admin
  // request). Flash-Lite leads because this tier only ever runs when Tier 1 has
  // already failed — usually because a shared free allowance is spent — so the
  // model with the most quota headroom and the fastest response is the one most
  // likely to actually finish the scan. The heavier Flash models follow as
  // quality fallbacks.
  static const List<String> _modelFallbackChain = [
    'gemini-3.1-flash-lite', // FIRST: highest quota, fastest; documented replacement for 2.0-flash-lite
    'gemini-3.6-flash',      // Documented replacement for 2.0-flash
    'gemini-2.5-flash',      // Older generation, still supported — extra headroom
  ];

  // ★ v25: Track if quota is exhausted (429) — all models on same key are blocked
  static bool _quotaExhausted = false;
  static DateTime? _quotaExhaustedAt;

  /// WHY the key is blocked, so the log can stop calling everything "quota".
  /// `'quota'` (429), `'forbidden'` (403), `'invalid_key'` (400 API_KEY_INVALID),
  /// or `''` when nothing is blocked.
  ///
  /// Added 2026-09-05 while chasing a live failure where this tier tried all
  /// three models and reported "no usable result" with no cause. An invalid or
  /// stale key produces exactly that shape: Google answers **400
  /// API_KEY_INVALID**, not 401/403, so it fell into the generic `else` branch,
  /// did NOT set [_quotaExhausted], and the caller dutifully burned two more
  /// round trips on a key that could never work — then said nothing useful about
  /// why. Fast, silent, and unactionable.
  static String keyBlockKind = '';

  /// Analyze image for safety hazards
  /// Returns structured hazard data or null on failure
  /// [kbContext] — optional knowledge bank content to inject into prompt for accurate regulations
  /// [sceneContext] — the observer's optional note about what the photo shows,
  /// rendered by [GeminiVision.sceneContextBlock]. Context for interpretation
  /// only; it is explicitly not evidence for a hazard. Defaults to empty.
  /// ★ v25: FAST BAIL on 429 — all models share same key/quota, no point trying others
  static Future<Map<String, dynamic>?> analyzeImage(Uint8List imageBytes,
      {String? kbContext, String sceneContext = ''}) async {
    if (!await isConfigured) return null;

    // If quota was exhausted recently (within 60s), skip entirely
    if (_quotaExhausted && _quotaExhaustedAt != null &&
        DateTime.now().difference(_quotaExhaustedAt!).inSeconds < 60) {
      print('GeminiDirectVision: ⏭ Skipping — quota exhausted ${DateTime.now().difference(_quotaExhaustedAt!).inSeconds}s ago');
      return null;
    }
    _quotaExhausted = false;
    keyBlockKind = '';

    final apiKey = await getApiKey();
    final selected = await getModel();
    final base64Image = base64Encode(imageBytes);

    // Admin's choice first, then the rest of the chain. Deduplicated so the
    // selected model is not retried, and filtered through _retiredModels so a
    // dead ID can never enter the attempt list.
    final attempts = <String>[
      selected,
      ..._modelFallbackChain,
    ].map((m) => _retiredModels[m] ?? m).toSet().toList();

    for (int i = 0; i < attempts.length; i++) {
      final model = attempts[i];
      print('GeminiDirectVision: ▶ [${i + 1}/${attempts.length}] $model');
      final result = await _callModel(model, apiKey, base64Image,
          kbContext: kbContext, sceneContext: sceneContext);

      // 429/403 is key-wide, not model-specific, so every remaining attempt
      // would fail the same way. This bail is correct — unlike the previous
      // one, which also gave up after a 404, a per-MODEL error the next model
      // in the chain would have survived.
      if (_quotaExhausted) {
        print('GeminiDirectVision: ⚡ Key-wide block on $model '
            '(${keyBlockKind.isEmpty ? 'unknown' : keyBlockKind}) — remaining '
            'models share the same key, bailing');
        return null;
      }

      if (result != null &&
          result['hazards'] != null &&
          (result['hazards'] as List).isNotEmpty) {
        print('GeminiDirectVision: ✓ SUCCESS on $model');
        result['_source'] = 'gemini_direct';
        result['_model'] = model;
        return result;
      }
    }

    print('GeminiDirectVision: ✗ All ${attempts.length} model(s) failed: '
        '${attempts.join(", ")}');
    return null;
  }

  /// Call a specific Gemini model for image analysis
  static Future<Map<String, dynamic>?> _callModel(String model, String apiKey, String base64Image, {String? kbContext, String sceneContext = ''}) async {
    final url = 'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

    // KB context goes INTO the prompt builder so it lands inside the citable
    // reference table, not after the instruction forbidding outside citations.
    final String prompt = await resolvedComprehensivePrompt(
        kbContext: kbContext ?? '', sceneContext: sceneContext);

    final requestBody = {
      'contents': [
        {
          'parts': [
            {
              'text': prompt
            },
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.15,
        'topP': 0.8,
        'maxOutputTokens': 8192,
        'responseMimeType': 'application/json',
      }
    };

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        // ★ v29 FIX: Force UTF-8 decode for non-English text support
        final responseText = utf8.decode(response.bodyBytes);
        final data = jsonDecode(responseText) as Map<String, dynamic>;
        final candidates = data['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'] as Map<String, dynamic>?;
          final parts = content?['parts'] as List?;
          if (parts != null && parts.isNotEmpty) {
            final text = parts[0]['text']?.toString() ?? '';
            return _parseHazardResponse(text);
          }
        }
        // HTTP 200 with nothing usable. This used to print "No candidates in
        // response" for three different causes, which is how a live failure on
        // 2026-09-05 came back with no diagnosable reason at all. Google puts the
        // reason in one of these three places and none of them were being read:
        //
        //   • promptFeedback.blockReason — a SAFETY filter refused the prompt or
        //     image outright, so there are genuinely zero candidates. Industrial
        //     photos (injuries, blood, restricted areas) do trip this.
        //   • candidates[0].finishReason — 'MAX_TOKENS' means the model ran out of
        //     output budget. On the Gemini 3.x thinking models the reasoning is
        //     billed to maxOutputTokens, so the 8192 here can be consumed before a
        //     single character of JSON is emitted, leaving `content` with NO
        //     `parts`. That looks identical to "no candidates" but needs the
        //     opposite fix (raise the budget / shorten the prompt).
        //   • usageMetadata — the numbers that prove which of the two it was.
        //
        // Logged, not acted on: the caller already falls through to the next
        // model, and guessing a remedy from one scan would be worse than printing
        // the facts.
        final blockReason = data['promptFeedback']?['blockReason']?.toString();
        final finishReason = (candidates != null && candidates.isNotEmpty)
            ? candidates[0]['finishReason']?.toString()
            : null;
        if (blockReason != null && blockReason.isNotEmpty) {
          print('GeminiDirectVision: [$model] ⚠ BLOCKED by safety filter '
              '(promptFeedback.blockReason=$blockReason) — the prompt or the '
              'photo was refused, so no output was generated. Not a quota or key '
              'problem; the next model will very likely refuse it too.');
        } else if (finishReason != null) {
          print('GeminiDirectVision: [$model] ⚠ HTTP 200 but no text part '
              '(finishReason=$finishReason, usage=${data['usageMetadata']}). '
              'MAX_TOKENS here means the thinking budget ate maxOutputTokens '
              'before any JSON was written.');
        } else {
          print('GeminiDirectVision: [$model] No candidates in response — '
              'body: ${responseText.substring(0, responseText.length.clamp(0, 300))}');
        }
        return null;
      } else if (response.statusCode == 429) {
        print('GeminiDirectVision: [$model] Rate limited (429) — ALL models on this key are blocked');
        keyBlockKind = 'quota';
        _quotaExhausted = true;
        _quotaExhaustedAt = DateTime.now();
        return null;
      } else if (response.statusCode == 403) {
        print('GeminiDirectVision: [$model] API key invalid or quota exceeded (403)');
        keyBlockKind = 'forbidden';
        _quotaExhausted = true;
        _quotaExhaustedAt = DateTime.now();
        return null;
      } else if (response.statusCode == 400 &&
          response.body.contains('API_KEY_INVALID')) {
        // ⚠ GOOGLE REPORTS A BAD KEY AS 400, NOT 401 OR 403. Verified live on
        // 2026-09-05: `{"error":{"code":400,"message":"API key not valid. Please
        // pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":
        // "API_KEY_INVALID"...`. Without this branch it fell to the generic `else`,
        // which treats a failure as per-model — so a single dead key cost three
        // full round trips per scan and printed nothing an admin could act on.
        // Matched on the `reason` code rather than the English sentence, which is
        // localisable.
        print('GeminiDirectVision: [$model] ✗ API KEY INVALID (400 '
            'API_KEY_INVALID) — the key is wrong, revoked, or restricted to '
            'other APIs/referrers. Every model shares it, so bailing. Fix it in '
            'Admin → System Health → Gemini.');
        keyBlockKind = 'invalid_key';
        _quotaExhausted = true;
        _quotaExhaustedAt = DateTime.now();
        return null;
      } else if (response.statusCode == 404) {
        // Model retired by Google. This is per-MODEL, so _quotaExhausted must
        // NOT be set — the caller has to be free to try the next model. Getting
        // this wrong is what made the whole tier fail on 2026-08-15.
        print('GeminiDirectVision: [$model] ⚠ MODEL RETIRED (404) — this ID no '
            'longer exists. Trying next model in chain.');
        print('GeminiDirectVision:   If this repeats for every model, update '
            'availableModels/_modelFallbackChain against '
            'https://ai.google.dev/gemini-api/docs/deprecations');
        return null;
      } else {
        print('GeminiDirectVision: [$model] Error ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
        return null;
      }
    } catch (e) {
      print('GeminiDirectVision: [$model] Exception: $e');
      return null;
    }
  }

  /// The shared hazard prompt plus the extra fields this tier alone asks for,
  /// with the admin's live severity, observation-type and WSA-cause vocabularies
  /// substituted in. Callers must use this, never a raw template — otherwise
  /// renaming a severity or a cause in the admin panel leaves this model
  /// emitting labels the app's dropdowns no longer accept.
  ///
  /// The body comes from [GeminiVision.resolvedHazardPrompt]. It used to come
  /// from a private 40,357-char template; see [_sectionAndWsaAppendix] for why
  /// that was collapsed and what was deliberately dropped with it.
  static Future<String> resolvedComprehensivePrompt(
      {String kbContext = '', String sceneContext = ''}) async {
    // Severities and observation types are substituted by the shared builder;
    // WSA causes are not, because no other tier asks for them.
    List<String> causes;
    try {
      causes = await AdminMasterData.getWsaCauses();
    } catch (_) {
      causes = List<String>.from(AdminMasterData.defaultWsaCauses);
    }
    final causeBlock = causes.isEmpty
        ? 'HAZARD CATEGORIES: none configured — omit "wsaCause" and "wsa".'
        : 'HAZARD CATEGORIES (use the EXACT wording below for "wsaCause" and "wsa"):\n'
            '${causes.join('\n')}';

    // ── The prompt body is GeminiVision's, not a copy ───────────────────────
    // Until 2026-09-03 this tier carried its own 40,357-char template while the
    // Groq/OpenRouter/Nara tiers shared a 17,521-char one. They had drifted into
    // different wording for the same safety-critical rules, and — because this
    // tier now runs FIRST on any device with a Gemini key — the template that
    // governed most real scans was the one that had never received the
    // anti-hallucination lessons written into the shared prompt. Composing from
    // the shared body is what stops that from recurring: there is now exactly
    // one place where "how to read a photograph" is written down, and this file
    // adds only the fields that are genuinely unique to it.
    //
    // sevEnum/typeList are resolved by the shared builder too, so they are not
    // substituted here; what remains local is section detection and the WSA
    // block, which no other tier asks for.
    final shared = await GeminiVision.resolvedHazardPrompt(
        kbContext: kbContext, sceneContext: sceneContext);

    return '$shared\n${_sectionAndWsaAppendix(causeBlock)}';
  }

  /// The fields this tier asks for that no other tier does, appended to the
  /// shared prompt rather than woven into a private copy of it.
  ///
  /// Deliberately short. The template this replaced spent 9,701 characters
  /// enumerating visual cues for each plant section and a further 8,937 listing
  /// hazard categories to sweep — 46% of the whole prompt telling a small model
  /// what it might find. Published work on VLM hallucination is consistent that
  /// this is counter-productive: an object named in the instructions becomes
  /// more likely to be reported whether or not it is in the frame, and asking
  /// for a sweep of many categories at once raises hallucination further than
  /// asking about one. Section detection needs the enum and a rule about
  /// abstaining, not a catalogue of cues.
  static String _sectionAndWsaAppendix(String causeBlock) {
    return '''
═══════════════════════════════════════════════════════
ADDITIONAL FIELDS FOR THIS DEPLOYMENT
═══════════════════════════════════════════════════════
The JSON object specified above gains the keys below. Everything already stated
about evidence, absence claims, inventory-gating and specificity applies to them
unchanged — these are extra fields, not a different task.

Top level, alongside "overallRisk":
  "detectedSection": "BLAST FURNACE|SMS|COKE OVEN|SINTER PLANT|ROLLING MILL|POWER PLANT|ELECTRICAL|GAS NETWORK|MATERIAL HANDLING|MAINTENANCE|WATER TREATMENT|TRANSPORT|REFRACTORY|OXYGEN PLANT|CIVIL|LABORATORY|GENERAL"
  "sectionConfidence": 0-100
  "sectionCues": "<the visible things that identify the section — plant named in
                   your sceneInventory, signage you can read, characteristic
                   equipment. If nothing in the frame identifies the section,
                   answer GENERAL with a low sectionConfidence and say so here.
                   GENERAL is a correct answer, not a failure.>"
  "wsa": [<only categories with visual evidence — may be empty>]
  "preventive": [<long-term measures, each citing a standard from the table>]
  "ptw_required": "<permit types implied by work you can SEE in progress, or 'None'>"
  "nearest_standard": "<primary standard from the verified table>"
  "section_specific_risks": [<at most 3, and ONLY risks bearing on something in
                              your sceneInventory. This field is the one most
                              often filled from general knowledge of a steel
                              plant; if the frame does not support any, return
                              an empty list.>]

Inside each hazard, alongside "type":
  "wsaCause": "<EXACT wording from the category list below>"

$causeBlock

★ Do not let "detectedSection" change what you report. Knowing a frame is a coke
  oven is a reason to describe what is in it precisely; it is never evidence that
  a coke-oven hazard is present. Report the photograph, not the section.''';
  }


  /// Parse the AI text response into structured hazard data
  /// ★ v33: Added JSON repair for truncated responses
  static Map<String, dynamic>? _parseHazardResponse(String text) {
    try {
      String jsonStr = text.trim();
      // Remove markdown fences if present
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll(RegExp(r'\n?```$'), '');
      }
      // Extract JSON object
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(jsonStr);
      if (jsonMatch != null) jsonStr = jsonMatch.group(0)!;

      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return _validateAndReturn(parsed);
    } catch (e) {
      print('GeminiDirectVision: JSON parse error: $e');
      print('GeminiDirectVision: Raw text: ${text.substring(0, text.length.clamp(0, 300))}');

      // ★ v33: Attempt to repair truncated JSON responses
      final repaired = _repairTruncatedJson(text);
      if (repaired != null) {
        print('GeminiDirectVision: ✓ Repaired truncated JSON — salvaged ${(repaired['hazards'] as List?)?.length ?? 0} hazards');
        return repaired;
      }
      return null;
    }
  }

  /// Validate and add metadata to parsed response
  static Map<String, dynamic> _validateAndReturn(Map<String, dynamic> parsed) {
    if (parsed['hazards'] == null) parsed['hazards'] = [];
    if (parsed['overallRisk'] == null) parsed['overallRisk'] = 'UNKNOWN';
    if (parsed['riskScore'] == null) parsed['riskScore'] = 0;
    if (parsed['confidence'] == null) parsed['confidence'] = 0;
    if (parsed['people'] == null) parsed['people'] = 0;
    if (parsed['summary'] == null) parsed['summary'] = 'Analysis complete.';
    // Left ABSENT rather than defaulted to '' when the model did not supply one.
    // HazardValidator treats a missing inventory as "grounding not checked"; an
    // empty string would be indistinguishable from that, but writing the key
    // makes the difference explicit to anyone reading a stored report.
    if (parsed['sceneInventory'] == null) parsed['sceneInventory'] = '';
    if (parsed['detectedSection'] == null) parsed['detectedSection'] = 'GENERAL';
    if (parsed['sectionConfidence'] == null) parsed['sectionConfidence'] = 0;
    if (parsed['sectionCues'] == null) parsed['sectionCues'] = '';
    if (parsed['section_specific_risks'] == null) parsed['section_specific_risks'] = [];

    // Add metadata
    parsed['_source'] = 'gemini_direct';
    parsed['_isOnline'] = true;

    return parsed;
  }

  /// ★ v33: Repair truncated JSON — salvage partial responses
  /// When maxOutputTokens cuts off mid-response, we still have valuable data
  static Map<String, dynamic>? _repairTruncatedJson(String text) {
    try {
      String jsonStr = text.trim();
      // Remove markdown fences
      if (jsonStr.startsWith('```')) {
        jsonStr = jsonStr.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll(RegExp(r'\n?```$'), '');
      }
      // Must start with {
      final startIdx = jsonStr.indexOf('{');
      if (startIdx < 0) return null;
      jsonStr = jsonStr.substring(startIdx);

      // Strategy 1: Try to close open arrays and objects progressively
      // Find the "hazards" array and try to close it
      final hazardsStart = jsonStr.indexOf('"hazards"');
      if (hazardsStart < 0) {
        // No hazards array found — try to just close the root object
        // Extract top-level fields we can find
        return _extractTopLevelFields(jsonStr);
      }

      // Try closing arrays/objects from the end
      String attempt = jsonStr;
      // Count unclosed brackets
      int braces = 0, brackets = 0;
      bool inString = false;
      bool escaped = false;
      for (int i = 0; i < attempt.length; i++) {
        final c = attempt[i];
        if (escaped) { escaped = false; continue; }
        if (c == '\\') { escaped = true; continue; }
        if (c == '"') { inString = !inString; continue; }
        if (inString) continue;
        if (c == '{') braces++;
        if (c == '}') braces--;
        if (c == '[') brackets++;
        if (c == ']') brackets--;
      }

      // Trim back to last complete object in the hazards array
      // Find the last complete "}" that's part of a hazard object
      int lastCompleteHazard = attempt.lastIndexOf('},');
      if (lastCompleteHazard < 0) lastCompleteHazard = attempt.lastIndexOf('}]');
      if (lastCompleteHazard < 0) {
        // Try to find any complete hazard object
        lastCompleteHazard = attempt.lastIndexOf('}');
      }

      if (lastCompleteHazard > hazardsStart) {
        // Cut after the last complete hazard object and close everything
        attempt = attempt.substring(0, lastCompleteHazard + 1);
        // Close: ], then any remaining }
        attempt += ']';
        // Close remaining braces
        int remainingBraces = 0;
        bool inStr = false;
        bool esc = false;
        for (int i = 0; i < attempt.length; i++) {
          final c = attempt[i];
          if (esc) { esc = false; continue; }
          if (c == '\\') { esc = true; continue; }
          if (c == '"') { inStr = !inStr; continue; }
          if (inStr) continue;
          if (c == '{') remainingBraces++;
          if (c == '}') remainingBraces--;
        }
        for (int i = 0; i < remainingBraces; i++) {
          attempt += '}';
        }

        try {
          final parsed = jsonDecode(attempt) as Map<String, dynamic>;
          if (parsed['hazards'] != null && (parsed['hazards'] as List).isNotEmpty) {
            return _validateAndReturn(parsed);
          }
        } catch (_) {}
      }

      // Strategy 2: Extract fields with regex
      return _extractTopLevelFields(jsonStr);
    } catch (_) {
      return null;
    }
  }

  /// Last-resort field extraction from partial JSON
  static Map<String, dynamic>? _extractTopLevelFields(String json) {
    try {
      final riskMatch = RegExp(r'"overallRisk"\s*:\s*"(\w+)"').firstMatch(json);
      final scoreMatch = RegExp(r'"riskScore"\s*:\s*(\d+)').firstMatch(json);
      final confMatch = RegExp(r'"confidence"\s*:\s*(\d+)').firstMatch(json);
      final peopleMatch = RegExp(r'"people"\s*:\s*(\d+)').firstMatch(json);
      final summaryMatch = RegExp(r'"summary"\s*:\s*"([^"]+)"').firstMatch(json);
      // The inventory is the FIRST key the prompt asks for, so in a response cut
      // short it is the field most likely to have survived intact — and it is
      // what the grounding check in HazardValidator runs against. Dropping it
      // here would silently disable that check on exactly the responses (partial,
      // repaired) where a hazard is most likely to have been half-invented.
      final inventoryMatch =
          RegExp(r'"sceneInventory"\s*:\s*"([^"]*)"').firstMatch(json);

      if (riskMatch == null && scoreMatch == null) return null;

      // Try to extract complete hazard objects
      final hazardObjects = <Map<String, dynamic>>[];
      final hazardRegex = RegExp(r'\{\s*"name"\s*:\s*"[^"]+?"[^}]*?"correctiveAction"\s*:\s*"[^"]+?"[^}]*?\}', dotAll: true);
      for (final m in hazardRegex.allMatches(json)) {
        try {
          final h = jsonDecode(m.group(0)!) as Map<String, dynamic>;
          hazardObjects.add(h);
        } catch (_) {}
      }

      if (hazardObjects.isEmpty && riskMatch == null) return null;

      final result = <String, dynamic>{
        'sceneInventory': inventoryMatch?.group(1) ?? '',
        'overallRisk': riskMatch?.group(1) ?? 'UNKNOWN',
        'riskScore': int.tryParse(scoreMatch?.group(1) ?? '0') ?? 0,
        'confidence': int.tryParse(confMatch?.group(1) ?? '0') ?? 0,
        'people': int.tryParse(peopleMatch?.group(1) ?? '0') ?? 0,
        'summary': summaryMatch?.group(1) ?? 'Analysis complete (partial response recovered).',
        'hazards': hazardObjects,
        '_source': 'gemini_direct_repaired',
        '_isOnline': true,
      };

      return result;
    } catch (_) {
      return null;
    }
  }
}
