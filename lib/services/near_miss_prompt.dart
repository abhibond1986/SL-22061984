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
// WHY THE DECISION IS FRAMED AS THREE ANSWERS AND NOT TWO
//
// The first version of this prompt asked "is this a near miss?" and the app
// refused everything that was not one. The fix said "YOUR JOB IS TO CLASSIFY,
// NOT TO REJECT", told the model that a report which is not a near miss "is
// almost always a perfectly valid unsafe act or unsafe condition", and
// described `hasHazard: false` only for degenerate input — empty,
// unintelligible, a maintenance request, plainly unrelated to safety. That left
// no exit for the ordinary case of intelligible, work-related text containing
// no hazard. "While walking inside his office he was singing a song" came back
// as an Unsafe Act, Slip/Fall, MEDIUM, at 90% confidence, with a corrective
// action advising workers not to sing. Both prompts were wrong in the same way:
// each offered the model one honest answer and one escape hatch that did not
// fit, so the escape hatch absorbed everything.
//
// So the decision is now explicitly three-way, and the third answer — real,
// work-related, but not an observation — is stated as plainly as the other two.
// Two things hold it in place: the grounding test (name the harm, then quote the
// words that put it there, and if the dangerous part had to come from the model
// the answer is false), which is the text-side counterpart of `sceneInventory`
// on the vision path; and three worked examples, one per answer, because the
// single positive example that used to stand alone taught the model to rescue
// borderline input and never the reverse. `NearMissGuard` in
// `near_miss_guard.dart` backs this up in Dart for the cases where the model
// ignores it.
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
  "reason": "one sentence saying WHY it is that category, quoting the words in the worker's input that decide it — or, when hasHazard is false, one sentence saying plainly that the description is not an unsafe act, unsafe condition or near miss, and what is missing (in the same language as the worker's input)",
  "refined": "the worker's report rewritten in clear professional safety language — correct grammar, proper terminology, states what was observed, where, and what could have happened (in the same language as the worker's input, NOT translated)",
  "correctiveAction": "specific corrective action to prevent recurrence — practical, actionable steps (in the same language as the worker's input)",
  $wsaRule,
  $severityRule,
  "detectedLanguage": "the language the worker spoke in (English/Hindi)"
}

THERE ARE THREE POSSIBLE ANSWERS, AND TWO OF THEM KEEP THE REPORT.

(1) It is a valid observation — an unsafe act, an unsafe condition or a near
    miss. Name which one in "category", set "hasHazard": true, and return
    "refined" and "correctiveAction". Being "not a near miss" is NOT a reason
    to turn a report away: this form records acts and conditions too and they
    are just as valuable. Do NOT ask the worker to rewrite it.

(2) It describes something real at work, but nothing in it is an unsafe act, an
    unsafe condition or a near miss — no hazard, no unsafe behaviour, nothing
    that nearly went wrong. Set "hasHazard": false and say so plainly in
    "reason". This is an honest answer, not a refusal of the worker.

(3) It is empty, unintelligible, or has nothing to do with the workplace. Set
    "hasHazard": false.

When "hasHazard" is false, leave "category", "wsaCause" and "severity" empty
("") — a description that is not an observation must not be filed under a type.

THE HAZARD MUST COME FROM THE WORKER'S WORDS, NOT FROM YOU. Before you set
"hasHazard": true, do both of these:
  (a) NAME THE HARM — who or what gets hurt or damaged, and how: a fall, a
      burn, a crush, a shock, an inhalation, an impact, a release.
  (b) POINT AT THE WORDS — quote the part of the worker's input that puts that
      harm there. That is what "reason" is for.
If you cannot do (b) without supplying the dangerous part yourself, the answer
is (2), not (1). A behaviour is an unsafe act only when there is a realistic
path from it to injury that a safety officer would act on — not merely a chain
of events you can imagine. Ordinary conduct at work, described on its own with
no hazard around it, is not an unsafe act.

CONFIDENCE MEASURES HOW FIRMLY THE WORKER'S OWN WORDS SUPPORT YOUR ANSWER, not
how fluent your answer reads. If the hazard rests on something you inferred
rather than something reported, confidence must be below 50. Reserve 80 and
above for input that names the hazard, the place or the harm outright.

$obsGuidance

SEVERITY means the POTENTIAL consequence if the situation had continued or
worsened, not what actually happened. A slippery walkway nobody fell on can
still be HIGH if the fall would be onto machinery.

CORRECTIVE ACTION GUIDANCE:
- Be specific and actionable (e.g., "Install guardrail at platform edge" not just "Fix the issue")
- Reference applicable safety measures (barricading, signage, PPE, LOTO, PTW)
- Include both immediate action AND preventive measure where applicable
- Keep it concise (1-2 sentences)

WORKED EXAMPLES — one of each answer, so that neither answer is the default:

- "one person was walking and there was a slippery surface" → answer (1),
  Unsafe Condition. The hazard is the state of the floor; no event has
  happened, so it is not a near miss. hasHazard true, and it gets a refined
  description and a corrective action like any other report. The harm is a
  fall; the words that put it there are "slippery surface", quoted from the
  worker. Both halves of the test are satisfied, so confidence is high.

- "while walking inside his office he was singing a song" → answer (2),
  hasHazard FALSE. Nothing here is unsafe: no hazard is named, no place is
  described as dangerous, nothing nearly happened, and singing while walking is
  ordinary conduct. Calling this a slip risk because singing is "distracting"
  would be inventing the hazard — nothing in the input mentions a floor, a
  slip, or anything to collide with. Note what would change the answer: "he was
  singing while walking under a suspended load" IS answer (1), because the load
  is in the input. The song never is.

- "the fan in the rest room is not working" → answer (3), hasHazard FALSE. A
  maintenance request. It would become answer (1) if the worker had added that
  the heat was making people dizzy, because then a harm is reported.

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
