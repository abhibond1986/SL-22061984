// lib/services/near_miss_prompt.dart
//
// ONE definition of the near-miss text-classification prompt.
//
// This prompt used to exist in three hand-synchronised copies: an inline
// ~50-line string in `near_miss_tab.dart`, a near-duplicate in
// `GroqService.classifyNearMiss`, and `getSailPrompt` in `apps_script_v14.js`.
// They had already drifted — one hardcoded five observation categories that the
// app's own dropdown did not offer, one still said "English" in the "refined"
// description and so quietly regressed the Hindi path. Every provider now
// builds its prompt here, so a rule can only be stated once.
//
// The Apps Script copy cannot import Dart, so it remains separate — but the
// Dart side now sends the fully-built prompt for the {action:'gemini'} route,
// which means `getSailPrompt` is only reached by callers that send raw text.
//
// The response contract every caller parses:
//   hasHazard, category, confidence, reason, refined, correctiveAction,
//   wsaCause, severity, detectedLanguage
// `near_miss_tab.dart` resolves category/wsaCause/severity through its own
// canonicalisers, so an off-list answer becomes '' rather than a stored value
// no dropdown offers. That is why the list rules below insist on exact wording.

import 'admin_master_data.dart';

class NearMissPrompt {
  /// Builds the classification prompt.
  ///
  /// [languageName] is the human-readable language the worker used ('English',
  /// 'Hindi', ...). The three master lists must be the same lists the form's
  /// dropdowns are built from; pass them empty to drop the constraint entirely
  /// rather than substituting guesses.
  static String build({
    required String text,
    required String languageName,
    String kbContext = '',
    required List<String> obsTypes,
    required List<String> wsaCauses,
    required List<String> severities,
  }) {
    final langInstruction = languageName == 'English'
        ? 'Respond with the "reason", "refined", and "correctiveAction" fields '
            'in English.'
        : 'IMPORTANT: The worker spoke in $languageName. You MUST write the '
            '"reason", "refined", and "correctiveAction" fields in '
            '$languageName (using native script). Do NOT translate to English.';

    // The knowledge bank is framed as authoritative. It used to be dumped in
    // unlabelled, which gave the model no reason to prefer this plant's own
    // uploaded standards over its general training.
    final kb = kbContext.trim();
    final kbBlock = kb.isEmpty
        ? ''
        : "PLANT SAFETY KNOWLEDGE (uploaded by this plant's safety admin — "
            'AUTHORITATIVE. Where it conflicts with your general knowledge, '
            'follow it, and cite clause/section numbers exactly as written):\n'
            '$kb\n\n';

    final categoryRule = obsTypes.isEmpty
        ? '"category": ""'
        : '"category": "one of (exact wording): ${obsTypes.join(', ')}"';
    // The leading number must survive: the WSA-13 dropdown values carry it, and
    // a stripped label fails the caller's canonical match.
    final wsaRule = wsaCauses.isEmpty
        ? '"wsaCause": ""'
        : '"wsaCause": "one of (exact wording, keep the leading number): '
            '${wsaCauses.join(', ')}"';
    final severityRule = severities.isEmpty
        ? '"severity": ""'
        : '"severity": "one of (exact wording): ${severities.join(', ')}"';

    // A list of type names alone leaves the model to invent the taxonomy, and
    // the act / condition / near-miss distinction is precisely the one it gets
    // wrong. Keep this in step with getSailPrompt in apps_script_v14.js.
    final obsGuidance = AdminMasterData.obsTypeGuidance(obsTypes);

    return '''$kbBlock
You are classifying a safety observation reported by a worker at SAIL (Steel Authority of India Limited).

WORKER'S INPUT: "$text"

$langInstruction

Analyze this and respond in STRICT JSON format:
{
  "hasHazard": true/false,
  $categoryRule,
  "confidence": 0-100,
  "reason": "one sentence saying WHY it is that category, quoting the words in the worker's input that decide it (in the same language as the worker's input)",
  "refined": "the worker's report rewritten in clear professional safety language — correct grammar, proper terminology, states what was observed, where, and what could have happened (in the same language as the worker's input, NOT translated)",
  "correctiveAction": "specific corrective action to prevent recurrence — practical, actionable steps (in the same language as the worker's input)",
  $wsaRule,
  $severityRule,
  "detectedLanguage": "the language the worker spoke in (English/Hindi)"
}

YOUR JOB IS TO CLASSIFY, NOT TO REJECT. This form records unsafe acts and
unsafe conditions as well as near misses, and all of them are valuable reports.
A description that is not a near miss is almost always a perfectly valid unsafe
act or unsafe condition — say which it is in "category" and carry on. Do NOT
refuse the report, do NOT ask the worker to rewrite it, and ALWAYS return
"refined" and "correctiveAction" whatever the category turns out to be.

Set "hasHazard": false ONLY when the text describes no safety hazard at all —
it is empty, unintelligible, a maintenance request, or plainly unrelated to
safety. Being "not a near miss" is NOT a reason to set it false.

$obsGuidance

SEVERITY means the POTENTIAL consequence if the situation had continued or
worsened, not what actually happened. A slippery walkway nobody fell on can
still be HIGH if the fall would be onto machinery.

CORRECTIVE ACTION GUIDANCE:
- Be specific and actionable (e.g., "Install guardrail at platform edge" not just "Fix the issue")
- Reference applicable safety measures (barricading, signage, PPE, LOTO, PTW)
- Include both immediate action AND preventive measure where applicable
- Keep it concise (1-2 sentences)

WORKED EXAMPLE — "one person was walking and there was a slippery surface":
this is an Unsafe Condition (the hazard is the state of the floor; no event has
happened, so it is not a near miss), hasHazard is true, and it gets a refined
description and a corrective action like any other report.

Respond ONLY with the JSON — no explanations outside JSON.''';
  }

  /// Same prompt, for callers that do not already hold the master lists.
  ///
  /// Each list falls back to its shipped default on error rather than to an
  /// empty list, because an empty list silently removes the constraint and the
  /// model then answers with whatever taxonomy it likes.
  static Future<String> buildFromMasterData({
    required String text,
    required String languageName,
    String kbContext = '',
  }) async {
    List<String> obsTypes;
    List<String> wsaCauses;
    List<String> severities;
    try {
      obsTypes = await AdminMasterData.getObsTypes();
    } catch (_) {
      obsTypes = List<String>.from(AdminMasterData.defaultObservationTypes);
    }
    try {
      wsaCauses = await AdminMasterData.getWsaCauses();
    } catch (_) {
      wsaCauses = List<String>.from(AdminMasterData.defaultWsaCauses);
    }
    try {
      severities = await AdminMasterData.getSeverities();
    } catch (_) {
      severities = List<String>.from(AdminMasterData.defaultSeverities);
    }
    return build(
      text: text,
      languageName: languageName,
      kbContext: kbContext,
      obsTypes: obsTypes,
      wsaCauses: wsaCauses,
      severities: severities,
    );
  }
}
