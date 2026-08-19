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

  /// SharedPreferences key holding the URL of the Apps Script AI proxy.
  ///
  /// ⚠ THIS IS NOT THE SYNC BACKEND URL, and the distinction is the whole
  /// reason this pref exists. There are TWO separate Apps Script deployments:
  ///
  ///   • the MAIN backend (SyncService._defaultBackendUrl) — incidents, users,
  ///     getMasterData. Handles no vision actions.
  ///   • the "Nara Router" project ([defaultProxyUrl] below) — Main.gs +
  ///     NaraVisionProxy.gs only. Handles `analyzeImageNara`.
  ///
  /// An earlier version of this file read `apps_script_url`/`sync_backend_url`
  /// here, which resolve to the MAIN backend — so every web scan POSTed
  /// `analyzeImageNara` to a project with no such handler and came back
  /// `Unknown action`, which the proxy path reported as a generic failure.
  /// Keep these two URLs in separate prefs so that a mistake in one cannot
  /// silently disable the other.
  static const String kPrefsProxyUrl = 'nara_proxy_url';
  static const String _kProxyUrl = kPrefsProxyUrl;

  /// Compile-time default for the AI proxy, so web works with ZERO
  /// configuration on a device that has never seen the admin panel.
  ///
  /// Same pattern and same reason as `SyncService._defaultBackendUrl`: the proxy
  /// URL is not a secret (the KEY is, and that stays in the proxy's Script
  /// Properties and never reaches a browser), so shipping it costs nothing and
  /// spares every user a setup step they have no way of knowing about. An admin
  /// can still override it via [setProxyUrl] when the deployment is rotated —
  /// a stored value always wins over this constant.
  /// Rotated 2026-08-19 to deployment AKfycbx0CUXs6VZg… (verified by GET: the
  /// page advertises `analyzeImageNara`, so it is the proxy project, not the
  /// sync backend). The previous ID was AKfycbz7rcn6yIr…; a NEW deployment ID
  /// stales this constant for every user, so prefer publishing a new *version*
  /// of an existing deployment, which keeps the URL fixed.
  static const String defaultProxyUrl =
      'https://script.google.com/macros/s/AKfycbx0CUXs6VZg-nIzTV039ThJL6ywa2rzK3xyIdHEmeC5-LAMjE6LsmMKG63oTg-TyIJt/exec';

  /// Ceiling for ONE call through the Apps Script proxy — deliberately NOT
  /// [GeminiVision.kAttemptTimeout].
  ///
  /// That constant is 20s and its comment forbids raising it without measuring a
  /// success, which is right: it bounds a DIRECT call to a vision provider. The
  /// proxy path is a different shape with strictly more hops, and 20s was proven
  /// too tight in the field on 2026-08-19 — the console showed
  /// `TimeoutException after 0:00:20.000000` on a request that was genuinely in
  /// flight (the earlier CORS failure had been instant, so a full-duration
  /// timeout is the signature of a slow round trip, not a blocked one).
  ///
  /// The hops, and where the time goes:
  ///   1. browser → script.google.com, uploading the base64 image
  ///   2. Apps Script cold start (a few seconds on a project that has been idle)
  ///   3. UrlFetchApp → router.bynara.id — MEASURED at 10447ms server-side
  ///      against mistral-medium-3-5, from the proxy's own execution log
  ///   4. a 302 to googleusercontent.com that the browser then follows
  ///
  /// So the provider leg alone consumes over half of the direct-call budget
  /// before the proxy overhead is counted. 45s covers the measured 10.4s with
  /// room for the other three hops, and is the same figure the direct path used
  /// before it was tightened. Do not trim it back on the assumption that a
  /// lighter model will be selected: mistral-medium-3-5 is [defaultModel] on
  /// purpose (it is the strongest model on the account's free plan), so 10.4s in
  /// step 3 is the expected case, not the bad case.
  ///
  /// Note that this tier is NOT inside `_kTier1Budget` (that clock is checked
  /// only inside the OpenRouter loop), so a stall here is paid in full. Since the
  /// 2026-08-19 reorder it runs LAST of the online providers, so the only thing
  /// it now delays is the offline fallback — the cost of a stall is much lower
  /// than when it sat in front of Gemini as Tier 1b.
  static const Duration kProxyTimeout = Duration(seconds: 45);

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
  /// mistral-medium-3-5, by admin decision (2026-08-17, reaffirmed 2026-08-19).
  ///
  /// ⚠ READ THIS BEFORE "OPTIMISING" THE COST. On 2026-08-19 I briefly changed
  /// this to mimo-v2.5-free on the reasoning that the per-1M prices on Nara's
  /// models page made mistral ~30x more expensive. That was WRONG for this
  /// account, in two ways:
  ///
  ///   1. This account is on Nara's **Free plan**, whose page says outright
  ///      "Included in the Free plan — usable at no cost", with a 10M-token
  ///      daily allowance. The price columns are the PAYG rates that would apply
  ///      if PAYG were on; it is off. So all of these models cost the same as
  ///      each other here: nothing.
  ///   2. mimo-v2.5-free is NOT ON THE FREE PLAN AT ALL, despite the '-free' in
  ///      its slug. Requesting it is what produced `HTTP 402 Payment Required`
  ///      and killed the tier outright — a "cheaper" default that could not run.
  ///
  /// The lesson worth keeping: a slug containing 'free' is not evidence, and a
  /// price column is not a bill. Check the account's PLAN before ranking models
  /// by cost, and prefer the model that is confirmed to WORK — a tier that 402s
  /// costs infinitely more per usable scan than the priciest one that answers.
  ///
  /// Latency is the honest tradeoff here: 10447ms server-side, 14594ms
  /// end-to-end through the proxy. That is why [kProxyTimeout] is 45s and why
  /// this tier sits late in the chain rather than leading it.
  static const String defaultModel = 'mistral-medium-3-5';

  /// Models offered in the Admin panel dropdown.
  ///
  /// VISION-CAPABLE AND ON THE FREE PLAN. Two independent filters, both verified
  /// against https://router.bynara.id/models on 2026-08-19:
  ///
  ///   • Vision — a text-only model here would not fail loudly. It would ignore
  ///     the image part and confidently describe nothing, producing a hazard
  ///     report with no relation to the photograph. The free plan lists plenty of
  ///     Text-only models (deepseek-v4-pro-free, laguna-s-2.1, ling-3.0-flash-free,
  ///     mistral-large, qwen-3.8-max-free, tencent-hy3-free) — none belong here.
  ///   • Free plan — anything outside it returns HTTP 402 and takes the whole
  ///     tier down. mimo-v2.5-free was REMOVED for exactly this reason; its name
  ///     says free, the plan page does not list it, and it 402'd on every scan.
  ///
  /// These four are the complete intersection: every model tagged Vision on the
  /// Free plan. Do not add a slug without checking BOTH columns.
  static const List<Map<String, String>> availableModels = [
    {'id': 'mistral-medium-3-5', 'name': 'Mistral Medium 3.5 (256K ctx — default, strongest)'},
    {'id': 'stepfun-3.7-flash',  'name': 'StepFun 3.7 Flash (262K ctx — flash tier)'},
    {'id': 'agnes-2.0-flash',    'name': 'Agnes 2.0 Flash (512K ctx — fastest tier)'},
    {'id': 'agnes-2.5-flash',    'name': 'Agnes 2.5 Flash (512K ctx)'},
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
  /// TRUE NOW (as of 2026-08-19): `router.bynara.id` does not send CORS headers,
  /// but on web we now route through Apps Script as a proxy. The proxy runs
  /// server-side and is not subject to CORS restrictions, so it can call
  /// NaraRouter and relay the result back to Flutter web.
  ///
  /// On mobile/desktop, we call NaraRouter directly (no proxy overhead).
  ///
  /// Deliberately separate from [isConfigured] rather than folded into it: the
  /// admin panel asks "is a key stored" to draw its status chip, and that
  /// answer is platform-independent.
  static bool get isReachableHere => true;

  /// What a provider call should actually test before spending latency here.
  ///
  /// THE ANSWER DIFFERS BY PLATFORM, because the key lives somewhere different
  /// on each:
  ///
  ///  • WEB — the request goes through the Apps Script proxy, which holds the key
  ///    in its own Script Properties and attaches the Authorization header
  ///    server-side. The browser never sees the key and does not need one, so
  ///    requiring [isConfigured] here would gate the provider on a value that is
  ///    irrelevant to whether the call can succeed. That would also defeat the
  ///    zero-configuration goal: a user who has never opened the admin panel has
  ///    no local key, yet their scans work fine. So web only asks "is there a
  ///    proxy to post to".
  ///  • MOBILE / DESKTOP — the call is direct, the device supplies the header
  ///    itself, so a locally stored key is genuinely required.
  ///
  /// A local key on web is still honoured if present (see [analyzeImage]); it is
  /// simply not a precondition.
  static Future<bool> get isUsableHere async {
    if (!isReachableHere) return false;
    if (kIsWeb) return (await getProxyUrl()).isNotEmpty;
    return isConfigured;
  }

  /// Whether a DIRECT call to [endpoint] can work from here — i.e. no proxy.
  ///
  /// ⚠ USE THIS, NOT [isUsableHere], IN ANY CALLER THAT POSTS TO [endpoint]
  /// ITSELF. [isUsableHere] became true on web when the Apps Script proxy landed,
  /// because the hazard path goes through it. A caller that still calls Nara
  /// directly — SopOcrService does, for both OCR and text summaries — would read
  /// that as permission, then spend a full [GeminiVision.kAttemptTimeout] on a
  /// request the browser blocks before it leaves, delaying its own fallback tier
  /// for a call that cannot succeed. Those callers want this test.
  ///
  /// The fix for such a caller is to route it through the proxy as well (the
  /// proxy takes an arbitrary prompt, so it is not hazard-specific), at which
  /// point it should switch to [isUsableHere].
  static Future<bool> get isDirectCallUsableHere async =>
      !kIsWeb && await isConfigured;

  /// Why [isUsableHere] said no, for logging. Empty string when it said yes.
  ///
  /// Exists so the chain can print an accurate reason instead of the old
  /// hardcoded "(no key configured)", which was wrong on web in both directions:
  /// it blamed a missing key when the real cause was CORS, and it would now blame
  /// a missing key on a device that correctly has none.
  static Future<String> get unusableReason async {
    if (await isUsableHere) return '';
    if (kIsWeb) return 'AI proxy URL is blank — see Admin → NaraRouter';
    return 'no $keyPrefix key stored on this device';
  }

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

  /// The model NaraRouter says it actually served, read off the response body,
  /// or null if the last call did not get that far.
  ///
  /// Exists because on web the CLIENT no longer decides the model — an unsynced
  /// browser omits it and the proxy substitutes its own NARA_MODEL. Labelling the
  /// AI Performance dashboard with the locally-guessed slug would attribute every
  /// zero-config scan's latency and cost to the wrong model, which is exactly the
  /// data that decides whether to keep this provider.
  static String? lastModelUsed;

  /// URL of the Apps Script AI proxy: the admin override if one is stored,
  /// otherwise the shipped [defaultProxyUrl].
  ///
  /// ⚠ DOES NOT FALL BACK TO `sync_backend_url`. It used to, and that was a bug:
  /// that pref names the MAIN backend, which has no `analyzeImageNara` handler,
  /// so every web scan got `Unknown action` back. See [kPrefsProxyUrl].
  ///
  /// Never returns empty unless an admin has explicitly stored a blank value, so
  /// "proxy not configured" is a deliberate state rather than the default one.
  static Future<String> getProxyUrl() async {
    await _ensurePrefs();
    final saved = (_prefs!.getString(_kProxyUrl) ?? '').trim();
    return saved.isEmpty ? defaultProxyUrl : saved;
  }

  /// Override the proxy URL. Pass an empty string to clear the override and
  /// fall back to [defaultProxyUrl].
  static Future<void> setProxyUrl(String url) async {
    await _ensurePrefs();
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      await _prefs!.remove(_kProxyUrl);
    } else {
      await _prefs!.setString(_kProxyUrl, trimmed);
    }
  }

  /// True when an admin has overridden the shipped default.
  static Future<bool> get hasProxyUrlOverride async {
    await _ensurePrefs();
    return (_prefs!.getString(_kProxyUrl) ?? '').trim().isNotEmpty;
  }

  /// Call NaraRouter through Apps Script proxy (web only).
  ///
  /// Apps Script runs server-side and is not subject to CORS restrictions,
  /// so it can call router.bynara.id and relay the result back. This adds
  /// ~200-500ms latency for the proxy hop, but that's negligible compared
  /// to the 10-20 second model inference time.
  static Future<Map<String, dynamic>?> _analyzeViaProxy(
    Uint8List bytes,
    String prompt,
    String model,
  ) async {
    lastStatus = null;
    lastWasRateLimited = false;
    lastModelUsed = null;

    final scriptUrl = await getProxyUrl();
    if (scriptUrl.isEmpty) {
      print('NaraVision: ⏭ AI proxy URL blank — an admin cleared it. Restore it '
          'in Admin → System Health → NaraRouter, or clear the override to fall '
          'back to the shipped default.');
      return null;
    }

    final imageBase64 = base64Encode(bytes);
    final requestBody = {
      'action': 'analyzeImageNara',
      'imageBase64': imageBase64,
      'prompt': prompt,
      // In practice always present — [analyzeImage] resolves it through
      // [getModel]. Kept conditional so an empty string is never sent as a model
      // name, which the proxy would forward verbatim to Nara as a 404.
      if (model.isNotEmpty) 'model': model,
      'maxTokens': 4096,
      'temperature': 0,
      'topP': 1,
      'seed': 42,
    };

    try {
      final response = await http
          .post(
            Uri.parse(scriptUrl),
            // ⚠ text/plain, NOT application/json. THIS LINE IS THE WHOLE POINT.
            //
            // application/json is not a CORS "simple request" content type, so
            // the browser sends an OPTIONS preflight first. An Apps Script web
            // app cannot answer OPTIONS — there is no doOptions hook — so the
            // preflight comes back without Access-Control-Allow-Origin and the
            // browser blocks the POST before it is ever sent. The failure text is
            // "Response to preflight request doesn't pass access control check",
            // which reads like the proxy is unreachable when in fact it was never
            // contacted.
            //
            // With text/plain there is no preflight. Apps Script still receives
            // the exact same body via e.postData.contents (it does not parse by
            // content type), then 302s to googleusercontent.com, which DOES send
            // Access-Control-Allow-Origin: * — so the browser follows it and the
            // JSON arrives.
            //
            // This is the established pattern everywhere else in the app; see the
            // comment at sync_service.dart:106. Copying application/json in here
            // is what made the proxy look broken after it had been verified
            // working server-side.
            headers: {'Content-Type': 'text/plain;charset=utf-8'},
            body: jsonEncode(requestBody),
          )
          .timeout(kProxyTimeout);

      // An Apps Script error page is HTML, not JSON — and the commonest causes
      // are operational, not code: the deployment is archived, or "Who has
      // access" is not Anyone. Detected before jsonDecode so the log names that
      // instead of a FormatException about '<'.
      if (response.body.trimLeft().startsWith('<')) {
        print('NaraVision: ✗ proxy returned HTML, not JSON (HTTP '
            '${response.statusCode}). The deployment is probably archived or '
            'its access is not set to "Anyone".');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final ok = data['ok'] as bool? ?? false;
      final statusCode = data['statusCode'] as int? ?? 500;
      lastStatus = statusCode;

      if (!ok) {
        final error = data['error']?.toString() ?? 'Unknown error';
        print('NaraVision: ⚠ Apps Script proxy error: $error (HTTP $statusCode)');

        // "Unknown action" means the POST reached an Apps Script deployment that
        // has no analyzeImageNara handler — almost always the MAIN sync backend
        // rather than the Nara Router project. Called out explicitly because the
        // generic message above sends you looking at NaraRouter, which is fine.
        if (error.contains('Unknown action')) {
          print('NaraVision: ✗ WRONG DEPLOYMENT. $scriptUrl answered but does '
              'not handle analyzeImageNara. This is the main sync backend, not '
              'the Nara Router proxy project. Fix the proxy URL, or add '
              'NaraVisionProxy.gs to that project and route the action.');
        }

        // RELAY THE PROVIDER'S OWN MESSAGE. On a failure the proxy still returns
        // NaraRouter's response in `body`, and that is where the actionable text
        // lives — the `error` field above describes the PROXY's view and is often
        // just 'Unknown error'. Discarding `body` on !ok is what turned a plain
        // "insufficient credits" into an opaque "Unknown error (HTTP 402)".
        final relayed = data['body']?.toString() ?? '';
        if (relayed.isNotEmpty) {
          print('NaraVision:   NaraRouter said: '
              '${relayed.length > 400 ? '${relayed.substring(0, 400)}…' : relayed}');
        }

        // Status codes are the provider's, forwarded verbatim by the proxy, so
        // they say what to actually DO about it. Named explicitly because the
        // generic message sends you debugging the proxy — which at this point has
        // already done its job correctly.
        switch (statusCode) {
          case 402:
            // Payment Required — and on a Free-plan account the cause is almost
            // never the balance. It is a model OUTSIDE the free plan, which Nara
            // will not route without PAYG enabled. Diagnosed 2026-08-19: the
            // request named mimo-v2.5-free, whose slug says free but which is not
            // on the plan's model list at all. Check the model before the wallet.
            print('NaraVision: ✗ HTTP 402 — "$model" is not on this account\'s '
                'Nara plan (a \'-free\' slug does NOT mean it is included). Pick '
                'one of ${availableModels.map((m) => m['id']).join(', ')} in '
                'Admin → NaraRouter, or enable PAYG at router.bynara.id. If the '
                'model IS on the plan, then the daily allowance or balance is '
                'the cause — check Billing.');
            break;
          case 401:
          case 403:
            print('NaraVision: ✗ HTTP $statusCode — NARA_API_KEY in the proxy '
                'project\'s Script Properties is missing, wrong or revoked. '
                'This key is the proxy\'s, NOT the one synced to devices.');
            break;
          case 404:
            print('NaraVision: ✗ HTTP 404 — model "$model" is not valid on this '
                'account\'s plan. Pick another in Admin → NaraRouter.');
            break;
          case 429:
            lastWasRateLimited = true;
            print('NaraVision: ✗ HTTP 429 — daily TOKEN allowance spent (Nara '
                'meters tokens, not requests: 10M/day on the free plan). Every '
                'free-plan model draws on the SAME allowance, so switching '
                'models will not restore it — it resets on its own.');
            break;
        }

        return null;
      }

      // Parse the NaraRouter response body from the proxy
      final naraBody = data['body']?.toString() ?? '';
      if (naraBody.isEmpty) {
        print('NaraVision: ⚠ Apps Script returned empty body');
        return null;
      }

      final naraData = jsonDecode(naraBody) as Map<String, dynamic>;
      final servedModel = naraData['model']?.toString();
      if (servedModel != null && servedModel.isNotEmpty) {
        lastModelUsed = servedModel;
        if (model.isEmpty) {
          print('NaraVision: proxy chose $servedModel (this device has no '
              'model preference — the server default applies)');
        } else if (servedModel != model) {
          // Worth shouting about: it means the deployed script is overriding or
          // ignoring the requested model, which is how a 30x-cost model got used
          // unnoticed on 2026-08-19. Cost and latency both follow what SERVED,
          // not what was asked for, so [lastModelUsed] above is the value the AI
          // Performance dashboard must log.
          print('NaraVision: ⚠ asked for $model but proxy served $servedModel '
              '— the deployed NaraVisionProxy.gs is overriding the request '
              '(check NARA_MODEL and that the script is the current revision)');
        }
      }
      final choices = naraData['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final content = choices[0]['message']?['content']?.toString() ?? '';
        // Use shared parser from GeminiVision
        return GeminiVision.parseVisionResponse(content);
      }

      print('NaraVision: ⚠ No choices in NaraRouter response via proxy');
      return null;
    } catch (e) {
      print('NaraVision: ✗ Apps Script proxy exception: $e');
      return null;
    }
  }

  /// Analyse an image and return the parsed hazard map, or null on any failure.
  ///
  /// On WEB: Routes through Apps Script proxy to bypass CORS restrictions.
  /// On MOBILE/DESKTOP: Calls router.bynara.id directly.
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
    lastModelUsed = null;

    // KEY CHECK IS PLATFORM-SPECIFIC — deliberately not hoisted above the web
    // branch. On web the proxy holds the key; demanding one here would reject
    // exactly the zero-config devices this path was built to serve.
    final apiKey = (await getApiKey()).trim();
    if (!kIsWeb && !apiKey.startsWith(keyPrefix)) {
      print('NaraVision: ⏭ skipped (no valid $keyPrefix key on this device)');
      return null;
    }
    final model = await getModel();

    // Shared prompt builder — includes the citable-regulation table with the KB
    // context spliced INTO it. Passing kbContext through matters: appending it
    // after the finished prompt would land it after the "never invent
    // regulation numbers not in this table" instruction, which tells the model
    // to ignore it.
    final prompt = await GeminiVision.resolvedHazardPrompt(
        kbContext: kbContext ?? '', sceneContext: sceneContext);

    // ON WEB: Route through Apps Script proxy to bypass CORS.
    //
    // THE MODEL IS ALWAYS SENT, resolved through [getModel] so [defaultModel]
    // applies client-side. An earlier version deliberately sent it EMPTY on a
    // device with no preference, to let the proxy's NARA_MODEL be the single
    // central source of truth. That backfired on 2026-08-19: the deployed proxy
    // was an older revision whose fallback is hardcoded to mistral-medium-3-5,
    // so "no opinion" was read as "use the 30x model" and every browser scan ran
    // it (console: 'proxy chose mistral-medium-3-5', 14594ms). Deferring to a
    // remote default means inheriting whatever revision happens to be deployed —
    // and script revisions are exactly what the app cannot see or verify.
    //
    // Being explicit makes the app authoritative on both platforms, so the Admin
    // dropdown means the same thing everywhere, and no Apps Script edit is needed
    // to correct a costly default. NARA_MODEL still applies if a client ever
    // omits the field.
    if (kIsWeb) {
      return _analyzeViaProxy(bytes, prompt, await getModel());
    }

    // ON MOBILE/DESKTOP: Call NaraRouter directly
    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';

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
        lastModelUsed = data['model']?.toString();
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
