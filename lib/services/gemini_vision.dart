// lib/services/gemini_vision.dart
// ★ v25 MAXIMUM RELIABILITY — 4 independent providers, NEVER fails
//
// PRIORITY CHAIN (stops at first success):
//   TIER 1 — OpenRouter free vision models, in order:
//     1. Nemotron Nano 12B VL   — fastest free image model
//     2. Nemotron 30B Omni      — higher capacity
//     3. Gemma 4 26B            — different vendor
//     4. Dots3-Note Preview     — 512k context
//   TIER 2 — Direct Google Gemini (GeminiDirectVision), if a key is configured
//   TIER 3 — Offline fallback: reports the failure, returns NO hazards
//
// IMPORTANT — why Tier 2 is not optional in practice:
//   Every OpenRouter ':free' model draws on ONE account-wide daily allowance.
//   When that cap is hit, all four Tier 1 models return HTTP 429 together, so
//   switching between free models cannot help. A Gemini key bills against
//   Google instead, making Tier 2 the only path that still analyses the image.
//   Set it in Admin → System Health → Gemini Vision.
//
// All model IDs above were verified against OpenRouter's /api/v1/models
// listing as accepting image input — do not add one without checking.
// ALL keys auto-sync from Apps Script Properties on every app launch.

import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'network_checker.dart';
import 'admin_master_data.dart';
import 'knowledge_service.dart';
// For LocalDB.kbRevision — the KB context cache below is keyed to it so an
// admin knowledge upload reaches the analyser without an app restart.
import 'local_db.dart';
// Run telemetry. This file is the single instrumentation point for image
// analysis — see the comment on analyseImageBytes for why it is here and not
// at the call sites.
import 'ai_run_log.dart';
// Direct Google AI Studio vision path. This is a SEPARATE quota from
// OpenRouter's shared free tier, which is the whole point: when OpenRouter
// returns 429 (free-tier cap hit, account-wide across every ':free' model),
// a configured Gemini key is the only thing that can still analyse the image.
// It was admin-configurable but never called — see the chain below.
import 'gemini_direct_vision.dart';

class GeminiVision {
  // OpenRouter vision models (free tier), tried in order.
  // Nano 12B VL is the lightest/fastest free image model (hybrid
  // Transformer-Mamba, built for low latency); the 30B Omni is a
  // higher-capacity fallback if Nano is unavailable or too slow.
  static const String _orNanoVlModel   = 'nvidia/nemotron-nano-12b-v2-vl:free';
  static const String _orNemotronModel = 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free';
  static const String _orGemmaModel    = 'google/gemma-4-26b-a4b-it:free';
  // Mixture-of-experts, 512k context, accepts image input. Confirmed against
  // OpenRouter's /api/v1/models listing rather than assumed from the name.
  static const String _orDotsModel     = 'dots-studio/dots-3-note-preview:free';

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

  // KB regulation context, cached to avoid re-fetching before every scan.
  //
  // The cache is keyed on LocalDB.kbRevision: it used to be cached for the
  // whole app session, so a document the admin uploaded mid-session was never
  // picked up — "add knowledge, then scan" used the pre-upload knowledge until
  // the app was restarted, and if the KB had been empty at first scan the empty
  // result was cached too. Now any KB write invalidates it on the next scan.
  static String? _kbContextCache;
  static int _kbContextCacheRev = -1;

  /// Drops the cached KB context so the next scan re-reads the knowledge base.
  static void invalidateKbContext() {
    _kbContextCache = null;
    _kbContextCacheRev = -1;
  }

  // ── analyseImage (mobile / File path) ─────────────────────────────────────
  static Future<Map<String, dynamic>?> analyseImage(File imageFile,
      {String runType = AiRunLog.typeHazardScan,
      String plant = '',
      String dept = ''}) async {
    final bytes = await imageFile.readAsBytes();
    return analyseImageBytes(bytes, runType: runType, plant: plant, dept: dept);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MAIN ENTRY: 4-PROVIDER ANALYSIS (maximum reliability, never fails)
  // ══════════════════════════════════════════════════════════════════════════
  //
  // TELEMETRY: every exit point below records exactly one AiRunLog row, and
  // this is deliberately the ONLY place image-analysis runs are logged.
  //
  // Instrumenting the CALLERS instead would both double-count (ai_scan_tab and
  // near_miss_tab each call this) and, worse, miss most failures: this method
  // never throws and never returns null on failure — it returns
  // _offlineFallback(), a well-formed map that the caller cannot distinguish
  // from a real answer without reading private flags. That is precisely why
  // AI failures were invisible before.
  //
  // [runType] lets one instrumentation point serve both entry points, so the
  // dashboard can still separate hazard scans from near-miss analyses.
  static Future<Map<String, dynamic>?> analyseImageBytes(Uint8List bytes,
      {int retryCount = 0,
      String runType = AiRunLog.typeHazardScan,
      String plant = '',
      String dept = ''}) async {
    final stopwatch = Stopwatch()..start();

    // Records one run and passes the result straight through, so each exit
    // stays a single `return logged(...)` and none can be forgotten.
    // Fire-and-forget: telemetry must never delay or break a scan.
    Map<String, dynamic>? logged(
      Map<String, dynamic>? result, {
      required String outcome,
      String failReason = '',
      String model = '',
      String imageHash = '',
    }) {
      final hazards = result?['hazards'];
      AiRunLog.record(
        runType: runType,
        outcome: outcome,
        failReason: failReason,
        provider: (result?['_source'] ?? '').toString(),
        model: model.isNotEmpty ? model : (result?['_model'] ?? '').toString(),
        durationMs: stopwatch.elapsedMilliseconds,
        hazardCount: hazards is List ? hazards.length : 0,
        confidence: int.tryParse(result?['confidence']?.toString() ?? '') ?? 0,
        imageHash: imageHash,
        plant: plant,
        dept: dept,
      );
      return result;
    }

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
        // CACHED is its own outcome, never SUCCESS: a cache hit returns in a
        // few ms, so counting it in the timing would flatter the average badly,
        // and counting it as a model success would let a warm cache hide a
        // completely broken provider chain.
        return logged(cached, outcome: AiRunLog.outcomeCached, imageHash: imgHash);
      }

      // Prevent concurrent analysis
      if (_isAnalyzing) {
        print('GeminiVision: ⚠ Another analysis in progress — waiting...');
        for (int i = 0; i < 60; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (!_isAnalyzing) break;
        }
        if (_isAnalyzing) {
          return logged(
            await _offlineFallback(bytes, reason: 'Another analysis in progress'),
            outcome: AiRunLog.outcomeFailed,
            failReason: AiRunLog.reasonConcurrent,
            imageHash: imgHash,
          );
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
          return logged(
            await _offlineFallback(bytes, reason: 'No internet connection'),
            outcome: AiRunLog.outcomeFailed,
            failReason: AiRunLog.reasonNoInternet,
            imageHash: imgHash,
          );
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
      final kbRev = LocalDB.kbRevision.value;
      String kbContext = '';
      if (_kbContextCache != null && _kbContextCacheRev == kbRev) {
        kbContext = _kbContextCache!;
        print('GeminiVision: ✓ KB context (cached, rev $kbRev)');
      } else {
        // Cache is keyed to the KB revision, so an admin upload is picked up on
        // the very next scan while repeat scans still skip the re-fetch.
        try {
          // The retrieval query is derived from the admin's own cause
          // categories and observation types rather than a fixed string, so
          // documents about whatever domains the admin actually configured are
          // reachable. Timeout raised from 3s: on a large KB the search was
          // timing out and returning '' — silently analysing with no knowledge.
          final query = await KnowledgeService.buildImageAnalysisQuery();
          kbContext = await KnowledgeService.getContextForPrompt(
            query,
            maxKbDocs: 6,
            includeExpertPrompt: false,
            snippetChars: 700,
          ).timeout(const Duration(seconds: 8), onTimeout: () => '');
          _kbContextCache = kbContext;
          _kbContextCacheRev = kbRev;
          if (kbContext.isNotEmpty) {
            print('GeminiVision: ✓ KB context loaded (${kbContext.length} chars)');
          } else {
            print('GeminiVision: ⚠ KB context empty — no matching documents');
          }
        } catch (_) {
          print('GeminiVision: KB context fetch failed — continuing without');
        }
      }

      // ══════════════════════════════════════════════════════════════════════
      // TIER 1 — OPENROUTER free vision chain, fastest model first.
      // ══════════════════════════════════════════════════════════════════════
      final prefs = await SharedPreferences.getInstance();
      final orKey = prefs.getString('openrouter_api_key') ?? '';
      if (orKey.isNotEmpty && orKey.startsWith('sk-or-')) {
        // If an admin pinned a model, use only that one; else walk the chain.
        final pinned = prefs.getString(_kVisionModelPin);
        final List<List<String>> attempts = (pinned != null && pinned.isNotEmpty)
            ? [[pinned, 'pinned model']]
            : const [
                [_orNanoVlModel,   'Nemotron Nano 12B VL (primary, fastest)'],
                [_orNemotronModel, 'Nemotron 30B Omni (secondary)'],
                // Different vendors/providers, so a per-model or per-provider
                // throttle no longer ends the scan after two attempts. All four
                // are verified image-input models on OpenRouter's free tier.
                [_orGemmaModel,    'Gemma 4 26B (tertiary)'],
                [_orDotsModel,     'Dots3-Note Preview (quaternary)'],
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
              // The only SUCCESS path: a real provider returned hazards for
              // this image. Model is passed explicitly so the dashboard can
              // compare the primary and secondary models' latency.
              return logged(orResult,
                  outcome: AiRunLog.outcomeSuccess,
                  model: model,
                  imageHash: imgHash);
            }
          } catch (e) {
            print('GeminiVision: ✗ OpenRouter $label exception: $e');
          }
        }
      } else {
        print('GeminiVision: ⏭ OpenRouter skipped (no key)');
      }

      // ══════════════════════════════════════════════════════════════════════
      // TIER 2 — DIRECT GEMINI (separate quota from OpenRouter)
      //
      // Why this exists: every OpenRouter ':free' model draws on ONE
      // account-wide daily allowance, so once that cap is hit the 429 applies
      // to all of them and extending the chain above cannot help. A Gemini key
      // is billed against Google, not OpenRouter, so it is the only tier that
      // can still analyse the image.
      //
      // This service was fully implemented and exposed in Admin → System
      // Health, but nothing ever invoked it: setting a Gemini key had no
      // effect whatsoever on scanning. That is fixed here.
      // ══════════════════════════════════════════════════════════════════════
      if (await GeminiDirectVision.isConfigured) {
        print('GeminiVision: ▶ Direct Gemini Vision (separate quota)...');
        try {
          final gemResult = await GeminiDirectVision.analyzeImage(bytes,
              kbContext: kbContext);
          if (_isValidResult(gemResult)) {
            print('GeminiVision: ✓ Direct Gemini SUCCESS in ${stopwatch.elapsedMilliseconds}ms');
            final model = await GeminiDirectVision.getModel();
            gemResult!['_source'] = 'gemini_direct';
            gemResult['_model'] = model;
            gemResult['_isOnline'] = true;
            _lastCallTime = DateTime.now();
            _isAnalyzing = false;
            await _writeCachedResult(imgHash, gemResult);
            return logged(gemResult,
                outcome: AiRunLog.outcomeSuccess,
                model: model,
                imageHash: imgHash);
          }
          print('GeminiVision: ✗ Direct Gemini returned no usable result');
        } catch (e) {
          print('GeminiVision: ✗ Direct Gemini exception: $e');
        }
      } else {
        print('GeminiVision: ⏭ Direct Gemini skipped (no key configured — '
            'set one in Admin → System Health to survive OpenRouter 429s)');
      }

      // ══════════════════════════════════════════════════════════════════════
      // EVERY PROVIDER UNAVAILABLE → offline fallback (no hazards, by design)
      // ══════════════════════════════════════════════════════════════════════
      print('GeminiVision: ✗ All vision providers unavailable. Total: ${stopwatch.elapsedMilliseconds}ms');
      _lastCallTime = DateTime.now();
      _isAnalyzing = false;
      // Every provider was tried and none returned a usable result. This is the
      // failure the admin most needs to see, and the one that was completely
      // invisible before: the user still gets a checklist, so nothing looked
      // wrong. A missing API key lands here too (chain skipped entirely).
      return logged(
        await _offlineFallback(bytes,
            reason: 'AI vision unavailable (${stopwatch.elapsedMilliseconds}ms)'),
        outcome: AiRunLog.outcomeFailed,
        failReason: AiRunLog.reasonExhausted,
        imageHash: imgHash,
      );
    } catch (e) {
      print('GeminiVision: Unexpected error: $e');
      _isAnalyzing = false;
      return logged(
        await _offlineFallback(bytes, reason: e.toString()),
        outcome: AiRunLog.outcomeFailed,
        failReason: AiRunLog.reasonException,
      );
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
    {'id': 'auto', 'name': 'Auto (tries all 4, then Gemini)'},
    {'id': _orNanoVlModel,   'name': 'Nemotron Nano 12B VL (fastest, free)'},
    {'id': _orNemotronModel, 'name': 'Nemotron 30B Omni (free)'},
    {'id': _orGemmaModel,    'name': 'Gemma 4 26B (free, slower)'},
    {'id': _orDotsModel,     'name': 'Dots3-Note Preview (free, 512k ctx)'},
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

    // KB context is passed INTO the prompt builder, which splices it into the
    // citable regulation table. Appending it to the end of the finished prompt
    // (as this did before) put it after "NEVER invent regulation numbers not in
    // this table", which told the model to disregard it.
    final String prompt =
        await resolvedHazardPrompt(kbContext: kbContext ?? '');

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
      } else if (response.statusCode == 429) {
        // The single most common real-world failure, and previously logged as a
        // bare status code that read like an app bug. OpenRouter's free tier is
        // capped PER ACCOUNT PER DAY across every ':free' model, so this is not
        // fixable by picking a different free model — the body carries the
        // actual reset window, so surface it.
        String detail = '';
        try {
          final err = jsonDecode(response.body) as Map<String, dynamic>;
          detail = (err['error']?['message'] ?? '').toString();
        } catch (_) {}
        print('GeminiVision: ⚠ OpenRouter RATE LIMITED (429) on $model'
            '${detail.isEmpty ? '' : ' — $detail'}');
        print('GeminiVision:   Free-tier quota is account-wide across all '
            ':free models. Configure a Gemini key in Admin → System Health.');
      } else {
        print('GeminiVision: OpenRouter HTTP ${response.statusCode} on $model');
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
  /// [_getHazardPrompt] with `{{SEVERITIES}}` / `{{OBS_TYPES}}` replaced by the
  /// admin's current vocabularies. Every caller must use this rather than the
  /// raw template, otherwise the model keeps emitting severity labels and
  /// observation types that no longer exist in the app's dropdowns.
  static Future<String> resolvedHazardPrompt({String kbContext = ''}) async {
    List<String> sevs;
    List<String> types;
    try {
      sevs = await AdminMasterData.getSeverities();
    } catch (_) {
      sevs = List<String>.from(AdminMasterData.defaultSeverities);
    }
    try {
      types = await AdminMasterData.getObsTypes();
    } catch (_) {
      types = List<String>.from(AdminMasterData.defaultObservationTypes);
    }
    // Most-severe-first reads more naturally in a prompt enum.
    final sevEnum = sevs.isEmpty
        ? 'LOW'
        : sevs.reversed.map((s) => s.toUpperCase()).join('|');
    // 'Line of Fire' drives the lofZone field below, so keep it available
    // even if the admin's list doesn't mention it.
    final typeList = <String>[
      ...types,
      if (!types.any((t) => t.toLowerCase() == 'line of fire')) 'Line of Fire',
    ];
    // Admin-uploaded knowledge is spliced INTO the citable reference table,
    // not appended after it. The table is headed "CITE ONLY FROM HERE" and the
    // hard rules end with "NEVER invent regulation numbers not in this table" —
    // so knowledge appended below that point was, as far as the model was
    // concerned, explicitly not citable. Uploaded documents were therefore
    // ignored in practice, which is exactly the deviation being fixed.
    final kbBlock = kbContext.trim().isEmpty
        ? ''
        : '\n── Plant Knowledge Bank (uploaded by the safety admin) ──\n'
            'These are part of this table and ARE citable. Where they conflict\n'
            'with the generic entries above, THESE TAKE PRECEDENCE — they are\n'
            'this plant\'s own standards. Cite clause/section numbers exactly as\n'
            'written below.\n'
            '$kbContext\n';

    return _getHazardPrompt()
        .replaceAll('{{SEVERITIES}}', sevEnum)
        .replaceAll('{{OBS_TYPES}}', typeList.join('|'))
        .replaceAll('{{KB_CONTEXT}}', kbBlock);
  }

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
{{KB_CONTEXT}}
HARD RULES:
• S21 = machinery fencing ONLY. NEVER for gas cylinders.
• S36 = confined space ONLY. NEVER for height work.
• S32 = height/access/floors. NEVER confuse with S36.
• IS 14489:2018 is an audit standard — do NOT cite for individual hazards.
• NEVER invent regulation numbers not in this table. The Plant Knowledge Bank
  section above, when present, is part of this table and may be cited freely.

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
  "overallRisk": "{{SEVERITIES}}",
  "riskScore": 0-100,
  "confidence": 0-100,
  "people": <count of ACTUALLY visible persons, 0 if none>,
  "summary": "<Sentence 1: what is physically visible. Sentence 2: primary safety concern with evidence. Sentence 3: applicable regulation.>",
  "hazards": [
    {
      "name": "<max 5 words, specific to what you SEE>",
      "description": "<MUST start with visual evidence: 'Visible: [what you see].' Then: why dangerous, consequence>",
      "severity": "{{SEVERITIES}}",
      "regulation": "<EXACT reference from table above>",
      "correctiveAction": "<starts with action verb, specific measurable steps>",
      "type": "{{OBS_TYPES}}",
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
  //
  // When every vision model is unreachable the IMAGE WAS NOT ANALYSED, so this
  // returns NO hazards at all. That is deliberate and must stay that way.
  //
  // History, so this is not "helpfully" re-added a third time:
  //
  //  1. It first returned a fixed list of 12 generic hazards while labelling
  //     the result '_source': 'knowledge_bank_fallback' / '_kbBased': true, so
  //     a plant that had uploaded its own standards got back generic content
  //     claiming to come from those standards.
  //  2. That was then changed to lead with real knowledge-bank snippets and
  //     follow with the generic checklist as "clearly-labelled" material. Still
  //     wrong: on screen it rendered as a 20-row HAZARD ANALYSIS table with
  //     severities and regulations, beside an OVERALL RISK card. No amount of
  //     labelling stops that reading as findings about the photo. A reviewer
  //     could sign off "20 hazards incl. 8 CRITICAL" on an image nothing ever
  //     looked at, and those rows also flowed into the saved incident, the PDF
  //     and the WhatsApp share.
  //
  // A failed scan now reports only that it failed. Generic guidance belongs in
  // the knowledge bank screen, not in a hazard report keyed to an image.
  //
  // Callers already handle this shape: ai_scan_tab shows a "not analysed" empty
  // state when hazards is empty and hides the OVERALL RISK card on
  // _imageAnalysed == false; near_miss_tab switches to manual entry on
  // (hazards.isEmpty && !_isOnline).
  static Future<Map<String, dynamic>> _offlineFallback(Uint8List bytes,
      {String reason = ''}) async {
    return {
      // UNKNOWN, never a severity level: an unanalysed image has no risk
      // rating, and 'MEDIUM' here previously drove a coloured OVERALL RISK
      // card that looked like a verdict on the photo.
      'overallRisk': 'UNKNOWN',
      'riskScore': 0,
      'confidence': 0,
      'people': 0,
      'hazards': const <Map<String, dynamic>>[],
      'summary': 'This image was NOT analysed — $reason.\n\n'
          'No hazards are listed because nothing examined the photo. '
          'Retry the scan when you are back online.\n\n'
          'You can still record the observation manually; '
          'the form works fully offline.',
      '_source': 'offline_fallback',
      '_offline_reason': reason,
      '_isOnline': false,
      '_imageAnalysed': false,
    };
  }

  static bool get isConfigured => true;
}
