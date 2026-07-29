// lib/services/gemini_vision.dart
// ★ v25 MAXIMUM RELIABILITY — 4 independent providers, NEVER fails
//
// PRIORITY CHAIN (OpenRouter only, stops at first success):
//   1. OpenRouter Nemotron Nano 12B VL (client) — PRIMARY (fastest free image model)
//   2. OpenRouter Nemotron 30B Omni (client) — SECONDARY (free, higher capacity)
//   3. Offline KB fallback (clean message, no network)
// NOTE: free-tier models share capacity and can queue; a paid endpoint
//       (drop ":free") is the way to get consistent ~5s latency.
//
// FAST-BAIL: On 429/quota errors, skips remaining models on same key immediately.
// ALL keys auto-sync from Apps Script Properties on every app launch.

import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'network_checker.dart';
import 'admin_master_data.dart';
import 'knowledge_service.dart';

class GeminiVision {
  // OpenRouter vision models (free tier), tried in order.
  // Nano 12B VL is the lightest/fastest free image model (hybrid
  // Transformer-Mamba, built for low latency); the 30B Omni is a
  // higher-capacity fallback if Nano is unavailable or too slow.
  static const String _orNanoVlModel   = 'nvidia/nemotron-nano-12b-v2-vl:free';
  static const String _orNemotronModel = 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free';
  static const String _orGemmaModel    = 'google/gemma-4-26b-a4b-it:free';

  // Rate-limiting between analyses (kept small — only affects back-to-back scans)
  static DateTime? _lastCallTime;
  static const Duration _minCallInterval = Duration(seconds: 2);

  // ── CONSISTENCY CACHE ──────────────────────────────────────────────────────
  // Keyed by image content hash so a repeat scan of the SAME photo returns the
  // SAME analysis. Capped so it can't grow unbounded.
  static const String _kResultCache = 'ai_result_cache_v1';
  static const int    _kMaxCachedResults = 60;

  /// Stable content hash of the image bytes (fast, dependency-free).
  static String _contentHash(Uint8List bytes) {
    // FNV-1a over a sampled subset (handles large images cheaply) plus length.
    int h = 0x811c9dc5;
    final step = bytes.length > 4096 ? bytes.length ~/ 2048 : 1;
    for (int i = 0; i < bytes.length; i += step) {
      h ^= bytes[i];
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return '${bytes.length}_${h.toRadixString(16)}';
  }

  static Future<Map<String, dynamic>?> _readCachedResult(String hash) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kResultCache);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final entry = map[hash];
      if (entry == null) return null;
      // Deep copy so callers can mutate freely.
      return Map<String, dynamic>.from(jsonDecode(jsonEncode(entry)) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCachedResult(
      String hash, Map<String, dynamic> result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kResultCache);
      final map = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      // Store a lean copy (no bulky transient fields).
      final lean = Map<String, dynamic>.from(result)..remove('_fromCache');
      map[hash] = lean;
      // Evict oldest if over cap (insertion order preserved by JSON map).
      if (map.length > _kMaxCachedResults) {
        final keys = map.keys.toList();
        for (int i = 0; i < map.length - _kMaxCachedResults; i++) {
          map.remove(keys[i]);
        }
      }
      await prefs.setString(_kResultCache, jsonEncode(map));
    } catch (_) {}
  }

  // Prevent concurrent AI calls
  static bool _isAnalyzing = false;

  // KB regulation context cached for the session (avoids re-fetching per scan).
  static String? _kbContextCache;

  // ── analyseImage (mobile / File path) ─────────────────────────────────────
  static Future<Map<String, dynamic>?> analyseImage(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    return analyseImageBytes(bytes);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MAIN ENTRY: 4-PROVIDER ANALYSIS (maximum reliability, never fails)
  // ══════════════════════════════════════════════════════════════════════════
  static Future<Map<String, dynamic>?> analyseImageBytes(Uint8List bytes,
      {int retryCount = 0}) async {
    final stopwatch = Stopwatch()..start();

    try {
      print('GeminiVision: ═══ STARTING ANALYSIS ═══ (${bytes.length} bytes)');

      // ══════════════════════════════════════════════════════════════════════
      // CONSISTENCY CACHE — the SAME image must always produce the SAME report.
      // AI vision models are non-deterministic, so re-scanning one photo could
      // otherwise yield different hazards/risk. We key results by a content
      // hash and return the stored analysis on a repeat scan.
      // ══════════════════════════════════════════════════════════════════════
      final imgHash = _contentHash(bytes);
      final cached = await _readCachedResult(imgHash);
      if (cached != null) {
        print('GeminiVision: ✓ Returning CACHED result for image $imgHash (consistent)');
        cached['_fromCache'] = true;
        return cached;
      }

      // Prevent concurrent analysis
      if (_isAnalyzing) {
        print('GeminiVision: ⚠ Another analysis in progress — waiting...');
        for (int i = 0; i < 60; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!_isAnalyzing) break;
        }
        if (_isAnalyzing) {
          return await _offlineFallback(bytes, reason: 'Another analysis in progress');
        }
      }
      _isAnalyzing = true;

      // Rate-limit
      if (_lastCallTime != null &&
          DateTime.now().difference(_lastCallTime!) < _minCallInterval) {
        final wait = _minCallInterval - DateTime.now().difference(_lastCallTime!);
        print('GeminiVision: Rate-limiting — waiting ${wait.inSeconds}s');
        await Future.delayed(wait);
      }

      // Network check (mobile only)
      if (!kIsWeb) {
        final networkStatus = await NetworkChecker.getNetworkStatus();
        if (!networkStatus['hasInternet']!) {
          print('GeminiVision: No internet → offline fallback');
          _isAnalyzing = false;
          return await _offlineFallback(bytes, reason: 'No internet connection');
        }
      }

      // Ensure the OpenRouter key is on device (auto-sync from server).
      {
        final p = await SharedPreferences.getInstance();
        final k = p.getString('openrouter_api_key') ?? '';
        if (!k.startsWith('sk-or-')) {
          print('GeminiVision: OpenRouter key missing — syncing from backend...');
          try {
            await AdminMasterData.syncFromBackend()
                .timeout(const Duration(seconds: 8), onTimeout: () => false);
          } catch (_) {}
        }
      }

      // ══════════════════════════════════════════════════════════════════════
      // FETCH KB CONTEXT — inject regulation knowledge from uploaded docs
      // ══════════════════════════════════════════════════════════════════════
      String kbContext = _kbContextCache ?? '';
      if (_kbContextCache == null) {
        // Fetch KB context once per session and cache it — it rarely changes
        // and re-fetching it added a few seconds before every scan.
        try {
          kbContext = await KnowledgeService.getContextForPrompt(
            'safety regulation statutory reference factories act IS standard',
            maxKbDocs: 5,
            includeExpertPrompt: false,
          ).timeout(const Duration(seconds: 3), onTimeout: () => '');
          _kbContextCache = kbContext; // cache (even empty) for the session
          if (kbContext.isNotEmpty) {
            print('GeminiVision: ✓ KB context loaded (${kbContext.length} chars)');
          }
        } catch (_) {
          print('GeminiVision: KB context fetch failed — continuing without');
        }
      } else {
        print('GeminiVision: ✓ KB context (cached)');
      }

      // ══════════════════════════════════════════════════════════════════════
      // OPENROUTER-ONLY vision chain. Fast Nano 12B VL first, then 30B Omni.
      // ══════════════════════════════════════════════════════════════════════
      final prefs = await SharedPreferences.getInstance();
      final orKey = prefs.getString('openrouter_api_key') ?? '';
      if (orKey.isNotEmpty && orKey.startsWith('sk-or-')) {
        // If an admin pinned a model, use only that one; else Nano VL → Omni.
        final pinned = prefs.getString(_kVisionModelPin);
        final List<List<String>> attempts = (pinned != null && pinned.isNotEmpty)
            ? [[pinned, 'pinned model']]
            : const [
                [_orNanoVlModel,   'Nemotron Nano 12B VL (primary, fastest)'],
                [_orNemotronModel, 'Nemotron 30B Omni (secondary)'],
              ];
        for (int i = 0; i < attempts.length; i++) {
          final model = attempts[i][0];
          final label = attempts[i][1];
          print('GeminiVision: ▶ [${i + 1}/${attempts.length}] OpenRouter $label...');
          try {
            final orResult = await _callOpenRouterVision(bytes, orKey, model, kbContext: kbContext);
            if (_isValidResult(orResult)) {
              print('GeminiVision: ✓ [${i + 1}/${attempts.length}] OpenRouter SUCCESS in ${stopwatch.elapsedMilliseconds}ms');
              orResult!['_source'] = 'openrouter_client';
              orResult['_model'] = model;
              orResult['_isOnline'] = true;
              _lastCallTime = DateTime.now();
              _isAnalyzing = false;
              // Cache so the SAME image always returns THIS result.
              await _writeCachedResult(imgHash, orResult);
              return orResult;
            }
          } catch (e) {
            print('GeminiVision: ✗ OpenRouter $label exception: $e');
          }
        }
      } else {
        print('GeminiVision: ⏭ OpenRouter skipped (no key)');
      }

      // ══════════════════════════════════════════════════════════════════════
      // OPENROUTER UNAVAILABLE → offline KB fallback
      // ══════════════════════════════════════════════════════════════════════
      print('GeminiVision: ✗ OpenRouter unavailable. Total: ${stopwatch.elapsedMilliseconds}ms');
      _lastCallTime = DateTime.now();
      _isAnalyzing = false;
      return await _offlineFallback(bytes,
          reason: 'AI vision unavailable (${stopwatch.elapsedMilliseconds}ms)');
    } catch (e) {
      print('GeminiVision: Unexpected error: $e');
      _isAnalyzing = false;
      return await _offlineFallback(bytes, reason: e.toString());
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  HELPER: Validate result has real hazards
  // ══════════════════════════════════════════════════════════════════════════
  static bool _isValidResult(Map<String, dynamic>? result) {
    if (result == null) return false;
    if (result['error'] != null) return false;
    if (result['hazards'] == null) return false;
    if ((result['hazards'] as List).isEmpty) return false;
    final summary = result['summary']?.toString().toLowerCase() ?? '';
    if (summary.contains('all providers exhausted') ||
        summary.contains('temporarily unavailable')) {
      return false;
    }
    return true;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  VISION MODEL SELECTION (OpenRouter)
  //  Admin can pin a specific model, or leave 'auto' to try Gemma → Nemotron.
  // ══════════════════════════════════════════════════════════════════════════
  static const String _kVisionModelPin = 'vision_model_pinned';

  /// Vision models offered in the Admin panel dropdown (id → label).
  static const List<Map<String, String>> groqVisionModels = [
    {'id': 'auto', 'name': 'Auto (Nano 12B VL → 30B Omni)'},
    {'id': _orNanoVlModel,   'name': 'Nemotron Nano 12B VL (fastest, free)'},
    {'id': _orNemotronModel, 'name': 'Nemotron 30B Omni (free)'},
    {'id': _orGemmaModel,    'name': 'Gemma 4 26B (free, slower)'},
  ];

  /// Admin-selected preferred vision model ('auto' = try the chain in order).
  static Future<String> getGroqVisionModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kVisionModelPin) ?? 'auto';
  }

  /// Save the admin's preferred vision model. 'auto' clears the pin so the
  /// chain (Gemma → Nemotron) is tried in order.
  static Future<void> setGroqVisionModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    if (model == 'auto' || model.isEmpty) {
      await prefs.remove(_kVisionModelPin);
    } else {
      await prefs.setString(_kVisionModelPin, model);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  OPENROUTER (client) — multimodal vision, model chosen by caller
  // ══════════════════════════════════════════════════════════════════════════
  static Future<Map<String, dynamic>?> _callOpenRouterVision(
      Uint8List bytes, String apiKey, String model, {String? kbContext}) async {
    final base64Image = base64Encode(bytes);
    final dataUrl = 'data:image/jpeg;base64,$base64Image';

    // Build prompt with KB context if available
    String prompt = _getHazardPrompt();
    if (kbContext != null && kbContext.isNotEmpty) {
      prompt += '\n\n═══════════════════════════════════════════════════════\n'
          'ADDITIONAL REFERENCE MATERIAL FROM KNOWLEDGE BANK\n'
          '═══════════════════════════════════════════════════════\n'
          'Use the following uploaded reference documents for ACCURATE regulation citations.\n'
          'If a specific clause/section is mentioned below, cite it EXACTLY as written:\n\n'
          '$kbContext';
    }

    final requestBody = {
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {'type': 'image_url', 'image_url': {'url': dataUrl}},
          ]
        }
      ],
      'max_tokens': 4096,
      // Deterministic decoding: temperature 0 + fixed seed minimise run-to-run
      // variance so a new image gets as reproducible a result as the model allows.
      // (The image-hash cache guarantees exact repeats are identical.)
      'temperature': 0,
      'top_p': 1,
      'seed': 42,
    };

    try {
      final response = await http.post(
        Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
          'HTTP-Referer': 'https://abhibond1986.github.io/SL-22061984/',
          'X-Title': 'SAIL Safety Lens',
        },
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final content = choices[0]['message']?['content']?.toString() ?? '';
          return _parseAIResponse(content);
        }
      } else {
        print('GeminiVision: OpenRouter HTTP ${response.statusCode}');
      }
    } catch (e) {
      print('GeminiVision: OpenRouter exception: $e');
    }
    return null;
  }


  // ══════════════════════════════════════════════════════════════════════════
  //  PARSE AI RESPONSE — extract JSON from model output
  // ══════════════════════════════════════════════════════════════════════════
  static Map<String, dynamic>? _parseAIResponse(String text) {
    if (text.isEmpty) return null;

    String jsonStr = text.trim();

    // Strip markdown code fences
    if (jsonStr.contains('```json')) {
      jsonStr = jsonStr.split('```json').last.split('```').first.trim();
    } else if (jsonStr.contains('```')) {
      final parts = jsonStr.split('```');
      if (parts.length >= 2) jsonStr = parts[1].split('```').first.trim();
    }

    // Find JSON boundaries
    final startIdx = jsonStr.indexOf('{');
    final endIdx = jsonStr.lastIndexOf('}');
    if (startIdx < 0 || endIdx < 0 || endIdx <= startIdx) return null;
    jsonStr = jsonStr.substring(startIdx, endIdx + 1);

    try {
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (parsed['hazards'] is List && (parsed['hazards'] as List).isNotEmpty) {
        return parsed;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  SHARED PROMPT — used by Groq & OpenRouter (client-side)
  // ══════════════════════════════════════════════════════════════════════════
  static String _getHazardPrompt() {
    return '''You are a senior industrial safety inspector for SAIL (Steel Authority of India Limited), with 30+ years field experience in IS 14489:2018 and Factories Act 1948.

═══════════════════════════════════════════════════════
ANTI-HALLUCINATION RULES (CRITICAL — READ FIRST)
═══════════════════════════════════════════════════════
★ ONLY report what you can PHYSICALLY SEE in this specific image.
★ For EACH hazard, you MUST describe the VISUAL EVIDENCE (colour, shape, position, object) that proves it exists.
★ If you cannot point to a specific pixel region proving a hazard, DO NOT report it.
★ NEVER assume hazards based on "typical" conditions — only report OBSERVED ones.
★ NEVER pad results with generic hazards to fill a quota.
★ 3 real hazards with evidence > 10 assumed ones without evidence.
★ "confidence" field must reflect YOUR certainty that hazards are real (not assumed).
  - confidence 80-100: Clear visual evidence, no ambiguity
  - confidence 50-79: Partial evidence, some interpretation needed
  - confidence below 50: Low-quality image or limited visibility
★ If image is blurry, dark, or shows nothing hazardous, return LOW risk with 1-2 hazards max.

═══════════════════════════════════════════════════════
METHODOLOGY — EVIDENCE-BASED INSPECTION
═══════════════════════════════════════════════════════
1. OBSERVE: What objects/people/equipment are VISIBLE? List them mentally.
2. ASSESS: For each visible item, is there a safety violation you can PROVE from the image?
3. CITE: Match ONLY to regulations from the table below. Never invent citations.
4. DESCRIBE: State what you SEE, not what you assume.

Scan order: foreground → middle → background, left → right.

═══════════════════════════════════════════════════════
REGULATION REFERENCE TABLE — CITE ONLY FROM HERE
═══════════════════════════════════════════════════════
── Gas Cylinders ──
  SMPV Rules 2016 Rule 14 = Storage (upright, chained, segregated, ventilated)
  SMPV Rules 2016 Rule 10 = Valve caps
  IS 4379:1981 = Colour code identification
  IS 7312:1987 = Storage of gas cylinders
  FA 1948 S37 = Explosive/inflammable dust, gas (No Smoking, separation)

── Machinery & Guards ──
  FA 1948 S21 = Fencing of machinery (rotating/moving parts ONLY)
  FA 1948 S22 = Work near machinery in motion

── Height & Access ──
  FA 1948 S32 = Floors, stairs, means of access (trip/slip/fall, safe access)
  FA 1948 S33 = Pits, sumps, openings in floors
  IS 3521:1999 = Safety harness for work at height

── Crane & Lifting ──
  FA 1948 S28 = Hoists and lifts
  FA 1948 S29 = Lifting machines, chains, ropes, tackles

── Pressure & Fire ──
  FA 1948 S31 = Pressure plant
  FA 1948 S37 = Explosive/inflammable gas, dust
  FA 1948 S38 = Fire precautions (exits, extinguishers)
  IS 2190:2010 = Fire extinguisher maintenance

── Electrical ──
  CEA Regulations 2010 Reg 36 = Earthing
  CEA Regulations 2010 Reg 45 = Insulation of conductors
  CEA Regulations 2010 Reg 46 = Protection against shock
  Indian Electricity Rules 1956 Rule 50 = Danger notice on HV

── PPE ──
  FA 1948 S35 = Protection of eyes
  FA 1948 S41C = PPE provision (employer duty)
  IS 2925:1984 = Safety helmets
  IS 3521:1999 = Safety harness
  IS 15298:2011 = Safety footwear

── Confined Space & Fumes ──
  FA 1948 S36 = Dangerous fumes/gases (confined space ONLY)

── Housekeeping ──
  FA 1948 S32 = Floors, stairs, means of access

── Chemical ──
  MSIHC Rules 1989 = Hazardous chemical storage/labelling

HARD RULES:
• S21 = machinery fencing ONLY. NEVER for gas cylinders.
• S36 = confined space ONLY. NEVER for height work.
• S32 = height/access/floors. NEVER confuse with S36.
• IS 14489:2018 is an audit standard — do NOT cite for individual hazards.
• NEVER invent regulation numbers not in this table.

═══════════════════════════════════════════════════════
LINE OF FIRE (LOF) — ONLY if persons visible near energy sources
═══════════════════════════════════════════════════════
"Line of Fire" = person positioned where energy/objects could strike them.
★ ONLY report LOF if you can SEE both the person AND the energy source in the image.
★ Do NOT assume LOF if no persons are visible.

Types:
• Person in path of crane/suspended load → FA 1948 S29
• Person near moving conveyor/machinery → FA 1948 S21
• Person near hot metal/slag/ladle → FA 1948 S41C
• Person below work at height → FA 1948 S33
• Person near pressurized lines → FA 1948 S31
• Person near rotating equipment → FA 1948 S21
• Person near gas cylinders during use → SMPV Rules 2016 Rule 14
• Person near electrical panel → CEA Regulations 2010 Reg 46

═══════════════════════════════════════════════════════
OUTPUT — VALID JSON ONLY (no markdown, no preamble)
═══════════════════════════════════════════════════════
{
  "overallRisk": "CRITICAL|HIGH|MEDIUM|LOW",
  "riskScore": 0-100,
  "confidence": 0-100,
  "people": <count of ACTUALLY visible persons, 0 if none>,
  "summary": "<Sentence 1: what is physically visible. Sentence 2: primary safety concern with evidence. Sentence 3: applicable regulation.>",
  "hazards": [
    {
      "name": "<max 5 words, specific to what you SEE>",
      "description": "<MUST start with visual evidence: 'Visible: [what you see].' Then: why dangerous, consequence>",
      "severity": "CRITICAL|HIGH|MEDIUM|LOW",
      "regulation": "<EXACT reference from table above>",
      "correctiveAction": "<starts with action verb, specific measurable steps>",
      "type": "Unsafe Act|Unsafe Condition|Line of Fire",
      "visualEvidence": "<brief: what specific object/condition in the image proves this hazard>",
      "bbox": {"x": 0.1, "y": 0.1, "w": 0.3, "h": 0.4},
      "lofZone": {"x1": 0.2, "y1": 0.3, "x2": 0.8, "y2": 0.7}
    }
  ]
}

FIELD RULES:
• "visualEvidence" is REQUIRED for every hazard — proves you actually see it.
• "bbox" is approximate location of hazard in image (normalized 0-1).
• "lofZone" is REQUIRED for "Line of Fire" type ONLY. Omit for others.
• "description" MUST begin with "Visible: ..." stating what you physically observe.
• Maximum 7 hazards. Quality over quantity.
• If nothing hazardous is visible, return overallRisk "LOW", riskScore <20, empty hazards [].''';
  }

  // ── Offline fallback ─────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _offlineFallback(Uint8List bytes,
      {String reason = ''}) async {
    // ═══════════════════════════════════════════════════════════════
    // KB-BASED CRITICAL ANALYSIS — Comprehensive steel plant inspection
    // When all AI models fail, provide FULL critical analysis using
    // Knowledge Bank (expert knowledge + admin-uploaded documents).
    // Covers ALL major hazard categories with accurate statutory refs.
    // ═══════════════════════════════════════════════════════════════
    try {
      // Fetch KB context from multiple safety domains for maximum coverage
      final kbContext = await KnowledgeService.getContextForPrompt(
        'safety hazard inspection steel plant PPE electrical height fire gas cylinder confined space crane machinery',
        maxKbDocs: 8,
        includeExpertPrompt: true,
      ).timeout(const Duration(seconds: 5), onTimeout: () => '');

      if (kbContext.isNotEmpty) {
        // Comprehensive critical hazard analysis from KB
        final hazards = <Map<String, dynamic>>[
          // ─── PPE COMPLIANCE ─────────────────────────────────────
          {
            'name': 'Head Protection — Helmet',
            'type': 'Unsafe Act',
            'severity': 'HIGH',
            'regulation': 'FA 1948 S35(1) — PPE; IS 2925:1984 — Industrial safety helmets',
            'recommendation': 'Helmet mandatory in ALL plant areas. Colour code: White=Officer, Yellow=Supervisor, Blue=Worker, Green=Visitor, Red=Fire crew. Check: No cracks, chin strap secured, within 3-year life.',
          },
          {
            'name': 'Body & Eye Protection',
            'type': 'Unsafe Act',
            'severity': 'MEDIUM',
            'regulation': 'FA 1948 S35; IS 4912 (Goggles), IS 5983 (Gloves), IS 5852 (Safety shoes), IS 6994 (Ear muffs)',
            'recommendation': 'Verify: Safety shoes with steel toe, eye protection for grinding/cutting/welding, hand protection matched to hazard, ear protection if noise >85dB.',
          },
          // ─── WORKING AT HEIGHT ──────────────────────────────────
          {
            'name': 'Fall from Height (>1.8m)',
            'type': 'Unsafe Condition',
            'severity': 'CRITICAL',
            'regulation': 'FA 1948 S32 — Floors, stairs, means of access; IS 3521:1999 — Full body harness',
            'recommendation': 'Full body harness with double lanyard MANDATORY above 1.8m. Anchor point min 15kN. Guardrails min 1m height. Toe boards. Safety net if >3m. Scaffold must be tagged GREEN.',
          },
          // ─── ELECTRICAL SAFETY ──────────────────────────────────
          {
            'name': 'Electrical Isolation / LOTOTO',
            'type': 'Unsafe Condition',
            'severity': 'CRITICAL',
            'regulation': 'CEA Regulations 2010 Reg 36, 44, 45; Indian Electricity Rules 1956 Rule 29, 50, 61',
            'recommendation': '5-step LOTOTO: Identify → Isolate → Lock → Tag → TryOut. Each worker applies OWN lock. Verify zero energy before work. No exposed wiring. Earthing ≤1Ω. Panel doors closed & locked.',
          },
          // ─── FIRE / HOT WORK ────────────────────────────────────
          {
            'name': 'Hot Work Permit & Fire Prevention',
            'type': 'Line of Fire',
            'severity': 'CRITICAL',
            'regulation': 'FA 1948 S38 — Fire precaution; IS 14489:2018 Cl.11.2 — Hot work permit system',
            'recommendation': 'Valid hot work permit MANDATORY. Fire watcher posted. Extinguisher within 6m (correct class). Combustibles removed 11m radius. Spark direction controlled. Post-work fire watch 30 min.',
          },
          // ─── GAS CYLINDER SAFETY ────────────────────────────────
          {
            'name': 'Gas Cylinder Storage & Separation',
            'type': 'Unsafe Condition',
            'severity': 'CRITICAL',
            'regulation': 'SMPV Rules 2016 Rule 14 Table-3 — Min 6m separation; IS 3933 — Colour coding',
            'recommendation': 'O₂ and flammable gas (C₂H₂/LPG): MINIMUM 6m apart OR firewall (1.5m high, 30-min rating). Stored upright & chained. Caps on when not in use. Colours: O₂=Black/White shoulder, C₂H₂=Maroon, LPG=Silver, N₂=Grey. NO oil/grease near O₂.',
          },
          // ─── CONFINED SPACE ─────────────────────────────────────
          {
            'name': 'Confined Space Entry',
            'type': 'Unsafe Act',
            'severity': 'CRITICAL',
            'regulation': 'FA 1948 S36 — Dangerous fumes & confined space; IS 14489:2018 Cl.8',
            'recommendation': 'Entry permit MANDATORY. Atmospheric testing: O₂ 19.5–23.5%, LEL <10%, CO <50ppm, H₂S <10ppm. Continuous 4-gas monitor. Standby person at entry. SCBA available. Rescue plan & tripod.',
          },
          // ─── CRANE / LIFTING ────────────────────────────────────
          {
            'name': 'Crane & Overhead Load',
            'type': 'Line of Fire',
            'severity': 'CRITICAL',
            'regulation': 'FA 1948 S33 — Hoists & lifts; IS 3757:1985 — Crane signals; IS 14489:2018 Cl.9',
            'recommendation': 'NEVER stand under suspended load. Barricade swing radius. Tagline for load control. SWL marked on slings. Annual load test current. Dedicated signal person. Horn before travel.',
          },
          // ─── MACHINERY / GUARDS ─────────────────────────────────
          {
            'name': 'Machine Guarding & Fencing',
            'type': 'Unsafe Condition',
            'severity': 'CRITICAL',
            'regulation': 'FA 1948 S21 — Fencing of machinery; S22 — Work near machinery in motion',
            'recommendation': 'ALL rotating/moving parts MUST be guarded. Interlocked guards. No operation with guard removed. No loose clothing/jewelry near rotating parts. Emergency stop within reach. LOTOTO for maintenance.',
          },
          // ─── HOUSEKEEPING ───────────────────────────────────────
          {
            'name': 'Housekeeping & Access',
            'type': 'Unsafe Condition',
            'severity': 'MEDIUM',
            'regulation': 'FA 1948 S32 — Floors, stairs & means of access; Ministry of Steel SG/03',
            'recommendation': 'Walkways clear (min 1m width). No trailing cables. Yellow markings visible. Material stacking ≤3× base width. Oil spills cleaned immediately. Emergency exits unobstructed.',
          },
          // ─── HOT METAL AREA ─────────────────────────────────────
          {
            'name': 'Hot Metal / Molten Splash Zone',
            'type': 'Line of Fire',
            'severity': 'CRITICAL',
            'regulation': 'IS 14489:2018 Cl.10 — Steel making safety; Ministry of Steel SG/12',
            'recommendation': 'Min 5m exclusion zone during tapping. Aluminized proximity suit + face shield MANDATORY. No moisture in ladle path (steam explosion risk). Ladle preheat min 800°C. Runner condition verified.',
          },
          // ─── GAS HAZARD (BF/CO) ─────────────────────────────────
          {
            'name': 'Toxic Gas Exposure (CO/BF Gas)',
            'type': 'Unsafe Condition',
            'severity': 'CRITICAL',
            'regulation': 'FA 1948 S36, S41A — Hazardous processes; IS 14489:2018 Cl.8.3',
            'recommendation': 'BF gas: CO 25–28% (TLV=50ppm, explosive 35–74%). Continuous gas monitoring. Wind direction indicator. Emergency escape route marked & drilled. SCBA at all BF gas areas.',
          },
        ];

        return {
          'overallRisk': 'HIGH',
          'riskScore': 70,
          'confidence': 35,
          'people': 0,
          'hazards': hazards,
          'summary':
              '⚠️ AI Vision models unavailable ($reason)\n\n'
              '📚 CRITICAL ANALYSIS FROM KNOWLEDGE BANK\n'
              'Comprehensive safety inspection checklist generated from expert knowledge & uploaded regulation documents.\n\n'
              '🔍 ${hazards.length} critical checkpoints covering: PPE, Height, Electrical, Fire, Gas Cylinders, Confined Space, Crane, Machinery, Housekeeping, Hot Metal, Toxic Gas.\n\n'
              '⚡ Review each hazard for applicable statutory references. '
              'Retry scan when internet is restored for AI-powered image-specific analysis with bounding boxes.',
          '_source': 'knowledge_bank_fallback',
          '_offline_reason': reason,
          '_isOnline': false,
          '_kbBased': true,
        };
      }
    } catch (_) {
      // KB fetch also failed — fall through to basic message
    }

    // Absolute fallback: no KB available either
    return {
      'overallRisk': 'UNKNOWN',
      'riskScore': 0,
      'confidence': 0,
      'people': 0,
      'hazards': [],
      'summary':
          'AI analysis unavailable ($reason).\n\n'
          'Form submission works fully offline. '
          'When you connect to internet later, you can retry for full AI-powered analysis.',
      '_source': 'offline_fallback',
      '_offline_reason': reason,
      '_isOnline': false,
    };
  }

  static bool get isConfigured => true;
}
