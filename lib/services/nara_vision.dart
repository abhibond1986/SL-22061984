// lib/services/nara_vision.dart
// NaraRouter vision provider — TIER 1b of the hazard-scan chain.
//
// WHAT THIS IS: NaraRouter (router.bynara.id) is a third-party gateway that
// resells several vendors' models behind ONE OpenAI-compatible endpoint, the
// same way OpenRouter does. It is a SEPARATE ACCOUNT with a SEPARATE DAILY
// ALLOWANCE, which is the entire reason it is worth having: when OpenRouter
// returns 429 (its free allowance is counted per account per day and shared
// across every ':free' model, so all Tier 1 models fail together), a Nara key
// is metered by Nara and can still analyse the image.
//
// Endpoint facts, taken from https://router.bynara.id/docs on 2026-08-17:
//   • base URL          https://router.bynara.id/v1
//   • chat endpoint     POST /v1/chat/completions   (OpenAI Chat Completions)
//   • auth              Authorization: Bearer sk-nry-...
//   • quotas            a per-MINUTE request rate AND a per-day token quota;
//                       exceeding the rate returns 429 with a rate_limited error
// Because the wire format is OpenAI-compatible, the request body below is the
// same shape as the OpenRouter call in gemini_vision.dart — including the
// {'type': 'image_url'} content part — so nothing about the prompt or the
// response parsing needed to be reinvented. Both are REUSED from GeminiVision
// (see [GeminiVision.resolvedHazardPrompt] and
// [GeminiVision.parseVisionResponse]) rather than copied, so a change to the
// hazard prompt or the JSON repair logic reaches this provider automatically.
// That is deliberately unlike gemini_direct_vision.dart, which carries its own
// duplicate copies of both and has drifted from them as a result.
//
// ⚠ QUOTA IS METERED IN TOKENS HERE, NOT REQUESTS. Nara counts input + output
// tokens against a daily quota (the free plan showed 17M/day). One hazard scan
// costs roughly 8k tokens worst case — ~1.5k prompt template, ~0.9k KB context,
// ~1.1-1.6k for a 900px image, and up to `max_tokens` on the way out. So the
// allowance is large, but a model priced above the cheap flash tier will drain
// it in proportion to how much it charges. The OpenRouter request ledger in
// GeminiVision does NOT and MUST NOT track this provider — see [analyzeImage].
//
// ⚠ MODEL SLUGS BELOW WERE READ OFF THE NARA FREE-MODELS PAGE, not verified
// against /v1/models (that endpoint needs a key, and returns 401 without one).
// If a scan comes back HTTP 404 here, the slug is the first thing to check.

import 'dart:convert';
import 'package:flutter/foundation.dart' show Uint8List, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'gemini_vision.dart';

class NaraVision {
  /// SharedPreferences key holding the Nara API key.
  ///
  /// Public because the cross-device sync in AdminMasterData writes it directly
  /// (it runs before any provider is constructed). Naming it here rather than
  /// repeating the literal there means a rename cannot leave the sync writing to
  /// a pref nothing reads — a silent failure that looks exactly like "the key
  /// did not sync".
  static const String kPrefsApiKey = 'nara_api_key';
  static const String _kApiKey = kPrefsApiKey;

  /// SharedPreferences key holding the selected model. Public for the same
  /// reason as [kPrefsApiKey] — the cross-device sync writes it directly.
  static const String kPrefsModel = 'nara_vision_model';
  static const String _kModel = kPrefsModel;

  /// Chat-completions URL. Base is `https://router.bynara.id/v1`.
  ///
  /// Public because SopOcrService posts its own OCR/structuring bodies here
  /// rather than going through [analyseImageBytes] — that method carries the
  /// hazard prompt and hazard-shaped parsing, which a transcription request must
  /// not inherit. One const so the URL is never typed twice.
  static const String endpoint =
      'https://router.bynara.id/v1/chat/completions';
  static const String _endpoint = endpoint;

  /// Every Nara key starts with this prefix (documented). Used to reject a
  /// half-pasted or wrong-provider key BEFORE it costs a scan its latency —
  /// the same guard `_configuredOpenRouterKeys` applies to 'sk-or-'.
  static const String keyPrefix = 'sk-nry-';

  /// Default model when the admin has not chosen one.
  ///
  /// mistral-medium-3-5 by explicit admin request (2026-08-17). Worth knowing
  /// what it costs: on the free-models page it was the MOST EXPENSIVE vision
  /// model listed ($0.30 in / $1.51 out per 1M) and the only one carrying no
  /// discount multiplier, while stepfun-3.7-flash ($0.04), agnes-2.0-flash
  /// (0.2x, $0.03) and mimo-v2.5-free (0.1x, $0.01) are 8-30x cheaper against
  /// the same shared daily token quota. It is also unmeasured for LATENCY,
  /// which is the whole reason this chain was reordered in the first place.
  /// If it turns out slow or drains the quota, switch the dropdown to a flash
  /// model rather than removing the provider.
  static const String defaultModel = 'mistral-medium-3-5';

  /// Models offered in the Admin panel dropdown.
  ///
  /// VISION-CAPABLE ONLY. A text-only model here would not fail loudly — it
  /// would ignore the image part and confidently describe nothing, producing a
  /// hazard report with no relation to the photograph. Do not add a slug to
  /// this list without confirming it is tagged Vision on Nara's models page.
  static const List<Map<String, String>> availableModels = [
    {'id': 'mistral-medium-3-5', 'name': 'Mistral Medium 3.5 (256K ctx — highest cost, unmeasured speed)'},
    {'id': 'stepfun-3.7-flash',  'name': 'StepFun 3.7 Flash (262K ctx — cheap, flash tier)'},
    {'id': 'agnes-2.0-flash',    'name': 'Agnes 2.0 Flash (0.2x discount — cheapest flash)'},
    {'id': 'agnes-2.5-flash',    'name': 'Agnes 2.5 Flash (0.3x discount)'},
    {'id': 'mimo-v2.5-free',     'name': 'MiMo v2.5 Free (1M ctx — lowest cost)'},
  ];

  static SharedPreferences? _prefs;

  static Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// True when a plausibly-valid Nara key is stored on this device.
  ///
  /// The prefix test matters more than a length test: this provider sits in the
  /// chain between OpenRouter and Gemini, so a key pasted into the wrong admin
  /// field would otherwise add a full [GeminiVision.kAttemptTimeout] of dead
  /// wait to every single scan before Gemini is even tried.
  static Future<bool> get isConfigured async {
    await _ensurePrefs();
    final key = (_prefs!.getString(_kApiKey) ?? '').trim();
    return key.startsWith(keyPrefix) && key.length > 20;
  }

  /// Whether Nara can be *reached* from this platform at all.
  ///
  /// FALSE ON WEB, and not because of a policy choice: `router.bynara.id`
  /// returns no `Access-Control-Allow-Origin` header, so a browser blocks the
  /// response before this app ever sees it. Confirmed 2026-08-19 from the live
  /// console at https://safetylens.in — every Nara call there was a CORS error,
  /// which means the only thing the attempt bought was a full
  /// [GeminiVision.kAttemptTimeout] of dead waiting on the *slowest* path, the
  /// one taken after another provider has already failed.
  ///
  /// Deliberately separate from [isConfigured] rather than folded into it: the
  /// admin panel asks "is a key stored" to draw its status chip, and on web that
  /// answer is still yes. Collapsing the two would make a correctly-saved key
  /// report "not configured" and send an admin off pasting it again.
  ///
  /// If Nara ever adds CORS headers (or a proxy is put in front of it — the
  /// Apps Script AI proxy already fronts the other providers for exactly this
  /// reason), delete this getter rather than special-casing call sites.
  static bool get isReachableHere => !kIsWeb;

  /// [isConfigured] AND [isReachableHere] — what a provider call should test.
  static Future<bool> get isUsableHere async =>
      isReachableHere && await isConfigured;

  static Future<String> getApiKey() async {
    await _ensurePrefs();
    return _prefs!.getString(_kApiKey) ?? '';
  }

  static Future<void> setApiKey(String key) async {
    await _ensurePrefs();
    await _prefs!.setString(_kApiKey, key.trim());
  }

  /// Selected model, falling back to [defaultModel].
  ///
  /// A saved slug outside [availableModels] is returned as-is rather than
  /// rewritten: unlike Google, Nara publishes no deprecation list, so an
  /// unrecognised slug is more likely to be a model this app has not caught up
  /// with than a dead one. The admin dropdown handles the display side.
  static Future<String> getModel() async {
    await _ensurePrefs();
    final saved = (_prefs!.getString(_kModel) ?? '').trim();
    return saved.isEmpty ? defaultModel : saved;
  }

  static Future<void> setModel(String model) async {
    await _ensurePrefs();
    await _prefs!.setString(_kModel, model.trim());
  }

  /// HTTP status of the most recent call, or null if it never completed
  /// (timeout / socket error). Read by the chain to explain the failure.
  static int? lastStatus;

  /// True when the last failure was a 429 — Nara's rate_limited error covers
  /// BOTH the per-minute request rate and the daily token quota, and the body
  /// does not reliably distinguish them, so the chain treats this as "Nara
  /// declined" without claiming to know which limit was hit. Guessing would
  /// mean telling a user at a live hazard either to wait a minute for a quota
  /// that resets tomorrow, or to come back tomorrow for a limit that clears in
  /// sixty seconds.
  static bool lastWasRateLimited = false;

  /// Analyse an image and return the parsed hazard map, or null on any failure.
  ///
  /// Deliberately mirrors `GeminiVision._callOpenRouterVision`, with two
  /// intentional differences:
  ///
  ///  1. NO QUOTA LEDGER WRITE. `GeminiVision._recordFreeUsage` tallies
  ///     OpenRouter's ~50-requests-per-day free allowance and feeds the admin
  ///     "free scans remaining" card. Counting a Nara request there would make
  ///     that card understate the OpenRouter allowance by however many scans
  ///     this provider served — an admin would see the budget draining while
  ///     OpenRouter had barely been touched, and would go chasing credits for
  ///     the wrong account. Nara's own quota is token-based and it publishes no
  ///     remaining-count, so there is nothing honest to display for it yet.
  ///  2. No `HTTP-Referer`/`X-Title` headers — those are OpenRouter's
  ///     attribution scheme, not part of the OpenAI-compatible spec.
  static Future<Map<String, dynamic>?> analyzeImage(Uint8List bytes,
      {String? kbContext, String sceneContext = ''}) async {
    lastStatus = null;
    lastWasRateLimited = false;

    final apiKey = (await getApiKey()).trim();
    if (!apiKey.startsWith(keyPrefix)) {
      print('NaraVision: ⏭ skipped (no valid $keyPrefix key)');
      return null;
    }
    final model = await getModel();

    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    // Shared prompt builder — includes the citable-regulation table with the KB
    // context spliced INTO it. Passing kbContext through matters: appending it
    // after the finished prompt would land it after the "never invent
    // regulation numbers not in this table" instruction, which tells the model
    // to ignore it.
    final prompt = await GeminiVision.resolvedHazardPrompt(
        kbContext: kbContext ?? '', sceneContext: sceneContext);

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
      // Same deterministic decoding as every other provider in the chain, so a
      // report does not read differently depending on which tier answered.
      'temperature': 0,
      'top_p': 1,
      'seed': 42,
    };

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(requestBody),
          )
          // Shared ceiling with Tier 1 — see [GeminiVision.kAttemptTimeout] for
          // the measurement it was sized from. This provider gets no special
          // allowance: an unmeasured model must not be able to stall a scan for
          // longer than a measured one.
          .timeout(GeminiVision.kAttemptTimeout);

      lastStatus = response.statusCode;
      if (response.statusCode == 200) {
        final data =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final content = choices[0]['message']?['content']?.toString() ?? '';
          // Shared parser: handles fenced JSON, truncated output repair and the
          // hazard-schema validation. Reusing it is what keeps a Nara result
          // interchangeable with an OpenRouter one downstream.
          return GeminiVision.parseVisionResponse(content);
        }
        print('NaraVision: ⚠ HTTP 200 but no choices in body on $model');
        return null;
      }

      // Body is logged truncated because Nara's errors are the only diagnostic
      // available — it publishes no status page.
      String detail = '';
      try {
        final err = jsonDecode(response.body) as Map<String, dynamic>;
        detail = (err['error']?['message'] ?? '').toString();
      } catch (_) {
        detail = response.body.length > 200
            ? '${response.body.substring(0, 200)}…'
            : response.body;
      }

      switch (response.statusCode) {
        case 429:
          lastWasRateLimited = true;
          print('NaraVision: ⚠ RATE LIMITED (429) on $model — could be the '
              'per-minute request rate OR the daily token quota; Nara does not '
              'reliably say which. $detail');
          break;
        case 401:
        case 403:
          print('NaraVision: ⚠ KEY REJECTED (${response.statusCode}) on $model '
              '— invalid, revoked or blocked. Check Admin → System Health. '
              '$detail');
          break;
        case 402:
          print('NaraVision: ⚠ PAYMENT REQUIRED (402) — the free plan quota is '
              'spent and pay-as-you-go is off. $detail');
          break;
        case 404:
          // The most likely failure on first use, hence its own case: the slugs
          // in [availableModels] came from the free-models page, not from a
          // verified /v1/models listing.
          print('NaraVision: ⚠ MODEL NOT FOUND (404) — "$model" is not a valid '
              'Nara alias, or is not available on this plan. $detail');
          break;
        default:
          print('NaraVision: HTTP ${response.statusCode} on $model — $detail');
      }
    } catch (e) {
      // Includes TimeoutException. Left as null lastStatus so the caller can
      // tell "did not respond" from "responded with a refusal".
      print('NaraVision: ✗ exception on $model: $e');
    }
    return null;
  }
}
