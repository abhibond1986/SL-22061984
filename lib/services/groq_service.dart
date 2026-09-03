// lib/services/groq_service.dart
// ★ v28: Groq AI Service — free, fast, reliable text correction
//
// Groq provides free API access (30 RPM, 6000 TPM) with very fast inference.
// Used as PRIMARY AI for near-miss text correction.
// Falls back to Apps Script (Gemini) if Groq fails.
//
// Model: openai/gpt-oss-20b (set 2026-09-03 by admin request).
//
// It replaced llama-3.3-70b-versatile, which had started returning 404
// model_not_found — the same decommissioning that previously took out
// mixtral-8x7b-32768 and gemma2-9b-it. There is now ONE model in
// [availableModels] by explicit choice; see the note there before adding another.
//
// Do not maintain a list of "models available on the free tier" in this comment.
// The three IDs that used to be listed here were all dead by the time anyone
// read them, and a stale comment is how a decommissioned ID gets picked. The
// live list is https://console.groq.com/docs/models.

import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'near_miss_prompt.dart';

class GroqService {
  static const String _kGroqApiKey = 'groq_api_key';
  static const String _kGroqModel = 'groq_model';
  static const String _apiUrl = 'https://api.groq.com/openai/v1/chat/completions';

  // Default model for near-miss text classification and rephrasing.
  // Changed 2026-09-03: llama-3.3-70b-versatile → openai/gpt-oss-20b.
  static const String defaultModel = 'openai/gpt-oss-20b';

  static SharedPreferences? _prefs;

  static Future<void> _ensurePrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Check if Groq API key is configured
  static Future<bool> get isConfigured async {
    await _ensurePrefs();
    final key = _prefs!.getString(_kGroqApiKey) ?? '';
    return key.isNotEmpty && key.startsWith('gsk_');
  }

  /// Get stored API key
  static Future<String> getApiKey() async {
    await _ensurePrefs();
    return _prefs!.getString(_kGroqApiKey) ?? '';
  }

  /// Save API key (from Admin panel)
  static Future<void> setApiKey(String key) async {
    await _ensurePrefs();
    await _prefs!.setString(_kGroqApiKey, key.trim());
  }

  /// Retired Groq model IDs → their current replacement.
  ///
  /// Why this map is essential and not cosmetic: the selected model is persisted
  /// per device in SharedPreferences. Groq decommissioned `mixtral-8x7b-32768`
  /// and `gemma2-9b-it`, and every install that had one saved kept posting it
  /// forever — Groq answers 404 `model_not_found`, `complete()` returned null
  /// without logging why, and the near-miss card silently fell through to the
  /// slower Apps Script path. Changing [defaultModel] alone does not reach those
  /// devices; [getModel] rewriting through this map is what makes them self-heal.
  ///
  /// Every value is [defaultModel] rather than a repeated literal, so the next
  /// decommissioning is a one-line change instead of six. That matters here:
  /// on 2026-09-03 `llama-3.3-70b-versatile` — which had been the replacement
  /// target for five of these entries — started 404ing itself, so the map was
  /// quietly redirecting dead IDs to another dead ID.
  static const Map<String, String> _retiredModels = {
    'mixtral-8x7b-32768': defaultModel,
    'gemma2-9b-it': defaultModel,
    'llama2-70b-4096': defaultModel,
    'llama-3.1-70b-versatile': defaultModel,
    'llama3-70b-8192': defaultModel,
    'llama3-8b-8192': defaultModel,
    // Retired 2026-09-03. 70b-versatile began returning 404 model_not_found;
    // 8b-instant still resolves but was dropped from the offered list by admin
    // decision, and anything absent from [availableModels] must appear here or
    // devices holding it are stranded on a model the build no longer supports.
    'llama-3.3-70b-versatile': defaultModel,
    'llama-3.1-8b-instant': defaultModel,
  };

  /// Get current model, transparently upgrading a retired saved ID.
  ///
  /// The rewrite is persisted so the admin panel dropdown also stops offering a
  /// dead model, and so this costs one write rather than a lookup per request.
  static Future<String> getModel() async {
    await _ensurePrefs();
    final saved = _prefs!.getString(_kGroqModel);
    if (saved == null || saved.trim().isEmpty) return defaultModel;
    final replacement = _retiredModels[saved.trim()];
    if (replacement != null) {
      debugPrint('GroqService: ⚙ Saved model "$saved" was decommissioned by '
          'Groq — migrating to "$replacement"');
      await _prefs!.setString(_kGroqModel, replacement);
      return replacement;
    }
    return saved.trim();
  }

  /// Set model preference
  static Future<void> setModel(String model) async {
    await _ensurePrefs();
    await _prefs!.setString(_kGroqModel, model);
  }

  /// Available models for the dropdown.
  ///
  /// Only IDs Groq still serves. `gemma2-9b-it` and `mixtral-8x7b-32768` were
  /// listed here long after Groq decommissioned them, so an admin could pick a
  /// model that could only ever return 404. Anything removed from this list must
  /// be added to [_retiredModels] in the same edit, or devices that already
  /// saved it are stranded.
  ///
  /// ONE ENTRY, deliberately (admin decision 2026-09-03). The consequence to
  /// understand: there is no longer a model to switch to from the admin panel if
  /// this ID is wrong or gets decommissioned — the near-miss card would fall
  /// through to the slower Apps Script path on every observation until a rebuild.
  /// Adding a second entry here is the whole fix if that happens; the dropdown,
  /// the clamp in admin_screen and [isSupportedModel] all read from this list.
  static const List<Map<String, String>> availableModels = [
    {'id': defaultModel, 'name': 'GPT-OSS 20B (default)'},
  ];

  /// True if [model] is one this build is willing to send.
  static bool isSupportedModel(String model) =>
      availableModels.any((m) => m['id'] == model.trim());

  /// Call Groq API for text completion
  /// Returns the AI response text, or null on failure.
  static Future<String?> complete(String prompt, {String? systemPrompt, double temperature = 0.3}) async {
    if (!await isConfigured) return null;

    final apiKey = await getApiKey();
    final model = await getModel();

    final messages = <Map<String, String>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }
    messages.add({'role': 'user', 'content': prompt});

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'temperature': temperature,
          'max_tokens': 1024,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        // ★ v29 FIX: Force UTF-8 decode — response.body defaults to Latin-1
        // which corrupts Hindi text
        final responseText = utf8.decode(response.bodyBytes);
        final data = jsonDecode(responseText) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final message = choices[0]['message'] as Map<String, dynamic>?;
          return message?['content']?.toString();
        }
        debugPrint('GroqService: 200 but no choices in response');
      } else {
        // This branch used to `return null` with no logging at all, which is how
        // a fleet-wide 404 `model_not_found` stayed invisible: the console showed
        // only the bare network 404 and the near-miss card looked like a slow
        // backend. Groq puts the actionable detail in the body, so log it.
        _logHttpFailure(response.statusCode, response.bodyBytes, model);
      }
    } catch (e) {
      debugPrint('GroqService: request failed — $e');
      return null;
    }
    return null;
  }

  /// Logs a non-200 from Groq with the part that says what is actually wrong.
  static void _logHttpFailure(int status, List<int> bodyBytes, String model) {
    String detail;
    try {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map;
        detail = '${err['code'] ?? ''} ${err['message'] ?? ''}'.trim();
      } else {
        detail = utf8.decode(bodyBytes);
      }
    } catch (_) {
      detail = '<unreadable body>';
    }
    if (detail.length > 400) detail = '${detail.substring(0, 400)}…';
    if (status == 429) {
      debugPrint('GroqService: 429 rate limited (model "$model") — $detail');
    } else if (status == 404) {
      debugPrint('GroqService: 404 for model "$model" — $detail. If this names '
          'the model, add it to _retiredModels so saved prefs migrate.');
    } else if (status == 401 || status == 403) {
      debugPrint('GroqService: $status — API key rejected. $detail');
    } else {
      debugPrint('GroqService: HTTP $status (model "$model") — $detail');
    }
  }

  /// ★ FIX: Multi-turn chat with conversation history.
  /// Accepts a list of messages [{role: 'user'|'assistant', content: '...'}]
  /// and returns the assistant's reply. Used by the chatbot for context-aware
  /// conversations where the bot remembers previous exchanges.
  static Future<String?> chat({
    required List<Map<String, String>> history,
    String? systemPrompt,
    double temperature = 0.4,
    int maxTokens = 1024,
  }) async {
    if (!await isConfigured || history.isEmpty) return null;

    final apiKey = await getApiKey();
    final model = await getModel();

    final messages = <Map<String, String>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }
    messages.addAll(history);

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'temperature': temperature,
          'max_tokens': maxTokens,
        }),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode == 200) {
        final responseText = utf8.decode(response.bodyBytes);
        final data = jsonDecode(responseText) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final message = choices[0]['message'] as Map<String, dynamic>?;
          return message?['content']?.toString();
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Convenience: Call Groq for near-miss text correction
  /// Returns corrected text or null (caller should fallback to Apps Script)
  static Future<String?> correctText({
    required String text,
    required String fieldLabel,
    required String language,
  }) async {
    final systemPrompt = '''You are a safety report text corrector for SAIL (Steel Authority of India Limited), a major steel manufacturing company in India.

Your job is to correct and improve text entered by field workers reporting near-miss incidents.

Rules:
- Fix grammar, spelling, and punctuation
- Use proper industrial safety terminology
- Make the text clear, concise, and professional
- Maintain the original meaning — do NOT add fabricated details
- If the input is in $language, respond in $language (same script)
- Do NOT translate to English unless the input is already in English
- Output ONLY the corrected text — no quotes, no explanation, no prefix''';

    final result = await complete(
      'Correct this "$fieldLabel" field text for a near-miss report:\n\n$text',
      systemPrompt: systemPrompt,
      temperature: 0.2,
    );

    if (result != null && result.trim().isNotEmpty) {
      String cleaned = result.trim();
      // Remove any markdown fences
      if (cleaned.startsWith('```')) {
        cleaned = cleaned.replaceAll(RegExp(r'^```\w*\n?'), '').replaceAll('```', '');
      }
      // Remove wrapping quotes
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        cleaned = cleaned.substring(1, cleaned.length - 1);
      }
      return cleaned.trim();
    }
    return null;
  }

  /// Full near-miss classification + refinement via Groq
  /// Returns parsed JSON map or null
  static Future<Map<String, dynamic>?> classifyNearMiss({
    required String text,
    required String language,
    String? kbContext,
  }) async {
    // The prompt itself lives in NearMissPrompt — see that file for why. This
    // method used to carry a near-duplicate that had already drifted from the
    // copy in near_miss_tab.dart.
    final prompt = await NearMissPrompt.buildFromMasterData(
      text: text,
      languageName: language,
      kbContext: kbContext ?? '',
    );

    final result = await complete(prompt, temperature: 0.2);
    if (result == null) return null;

    try {
      String jsonStr = result.trim();
      // Extract JSON from possible markdown fences
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(jsonStr);
      if (jsonMatch != null) jsonStr = jsonMatch.group(0)!;
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Groq: JSON parse error: $e');
      return null;
    }
  }
}
