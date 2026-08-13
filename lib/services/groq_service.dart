// lib/services/groq_service.dart
// ★ v28: Groq AI Service — free, fast, reliable text correction
//
// Groq provides free API access (30 RPM, 6000 TPM) with very fast inference.
// Used as PRIMARY AI for near-miss text correction.
// Falls back to Apps Script (Gemini) if Groq fails.
//
// Models available on free tier:
//   - llama-3.1-8b-instant (fastest, good for text correction)
//   - llama-3.3-70b-versatile (best quality, slightly slower)
//   - gemma2-9b-it (good multilingual support)

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'admin_master_data.dart';

class GroqService {
  static const String _kGroqApiKey = 'groq_api_key';
  static const String _kGroqModel = 'groq_model';
  static const String _apiUrl = 'https://api.groq.com/openai/v1/chat/completions';

  // Default model — fast and good for text correction
  static const String defaultModel = 'llama-3.3-70b-versatile';

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

  /// Get current model
  static Future<String> getModel() async {
    await _ensurePrefs();
    return _prefs!.getString(_kGroqModel) ?? defaultModel;
  }

  /// Set model preference
  static Future<void> setModel(String model) async {
    await _ensurePrefs();
    await _prefs!.setString(_kGroqModel, model);
  }

  /// Available models for the dropdown
  static const List<Map<String, String>> availableModels = [
    {'id': 'llama-3.3-70b-versatile', 'name': 'Llama 3.3 70B (Best quality)'},
    {'id': 'llama-3.1-8b-instant', 'name': 'Llama 3.1 8B (Fastest)'},
    {'id': 'gemma2-9b-it', 'name': 'Gemma 2 9B (Good multilingual)'},
    {'id': 'mixtral-8x7b-32768', 'name': 'Mixtral 8x7B (Balanced)'},
  ];

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
      } else if (response.statusCode == 429) {
        // Rate limited — caller should fallback
        print('Groq: Rate limited (429). Falling back.');
        return null;
      } else {
        final errorText = utf8.decode(response.bodyBytes);
        print('Groq: Error ${response.statusCode}: ${errorText.substring(0, errorText.length.clamp(0, 200))}');
        return null;
      }
    } catch (e) {
      print('Groq: Exception: $e');
      return null;
    }
    return null;
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
    // Observation types come from the admin panel. This used to be a
    // hardcoded five-value enum that didn't match the app's own dropdown, so
    // the AI could return a category the form then rejected.
    List<String> obsTypes;
    try {
      obsTypes = await AdminMasterData.getObsTypes();
    } catch (_) {
      obsTypes = List<String>.from(AdminMasterData.defaultObservationTypes);
    }
    final categoryRule = obsTypes.isEmpty
        ? '"category": ""'
        : '"category": "one of (exact wording): ${obsTypes.join(', ')}"';

    final langInstruction = language == 'English'
        ? 'Respond with "reason", "refined", and "correctiveAction" fields in English.'
        : 'IMPORTANT: The worker spoke in $language. Write "reason", "refined", and "correctiveAction" in $language (native script). Do NOT translate to English.';

    final prompt = '''${kbContext ?? ''}

You are analyzing a potential near miss incident reported by a worker at SAIL (Steel Authority of India Limited).

WORKER'S INPUT: "$text"

$langInstruction

Respond in STRICT JSON format:
{
  "isNearMiss": true/false,
  "confidence": 0-100,
  "reason": "brief explanation (in worker's language)",
  "refined": "rewritten professional near-miss description with safety terminology (in worker's language)",
  "correctiveAction": "specific corrective action to prevent recurrence — practical, actionable steps (in worker's language)",
  $categoryRule,
  "detectedLanguage": "English/Hindi"
}

CORRECTIVE ACTION GUIDANCE:
- Be specific and actionable (e.g., "Install guardrail at platform edge" not just "Fix the issue")
- Reference applicable safety measures (barricading, signage, PPE, LOTO, PTW)
- Include both immediate action AND preventive measure where applicable
- Keep it concise (1-2 sentences)

NEAR MISS DEFINITION: An unplanned event that DID NOT result in injury/illness/damage but HAD THE POTENTIAL to do so.

NOT A NEAR MISS: routine observations, planned maintenance, general complaints, requests, or situations with no potential for harm.

Respond ONLY with JSON — nothing else.''';

    final result = await complete(prompt, temperature: 0.2);
    if (result == null) return null;

    try {
      String jsonStr = result.trim();
      // Extract JSON from possible markdown fences
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(jsonStr);
      if (jsonMatch != null) jsonStr = jsonMatch.group(0)!;
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      print('Groq: JSON parse error: $e');
      return null;
    }
  }
}
