// lib/services/sop_safety_analysis.dart
//
// The safety layer over a scanned SOP/SMP. Takes the OCR text that
// SopOcrService already produced and asks the model one further question:
// what does this document REQUIRE of the person about to do the job?
//
// Deliberately a separate pass from SopOcrService.structure(), not extra keys on
// the same prompt. Three reasons, in order of importance:
//
//   1. They fail independently. Structuring fails on OCR quality; analysis fails
//      on schema validity. Merged, one bad key would cost the clause list too,
//      and the clause list is what the knowledge base is built from.
//   2. The structuring prompt is deliberately literal — "keep clause text close
//      to the original wording". Safety analysis has to interpret. Asking one
//      prompt to be both literal and interpretive is how invented requirements
//      get in.
//   3. Re-running the analysis after a user edits the OCR text must not re-cost
//      the clause extraction.
//
// WHAT THIS FILE WILL NOT DO: invent a requirement. Every requirement and every
// checklist item carries a source page and a verbatim source_text, and
// [_verify] checks that the quoted text is actually present in the OCR output
// before the requirement is trusted. Anything that fails that check is kept but
// marked unverified, never silently shown as if the document said it. Model
// suggestions that are genuinely not in the document live in a separate list
// with a separate label, and the UI must never merge the two.
//
// NOTHING IN THE HAZARD-SCAN OR NEAR-MISS PATH IS TOUCHED. This file only reads
// two public helpers that already exist: SopOcrService.askTextModel for the
// provider chain, and GeminiVision.parseVisionResponse for tolerant JSON
// extraction.
//
// ignore_for_file: avoid_print

import 'ai_run_log.dart';
import 'gemini_vision.dart';
import 'sop_ocr_service.dart';

/// How badly it hurts to get this one wrong.
///
/// Three levels, not five: the model cannot reliably distinguish more, and a
/// scale finer than the reader's decision ("stop and fix" vs "check before
/// starting") is false precision on a safety screen.
enum SopCriticality { high, medium, low }

SopCriticality _criticalityOf(String raw) {
  final s = raw.trim().toUpperCase();
  if (s.startsWith('H') || s == 'CRITICAL') return SopCriticality.high;
  if (s.startsWith('L')) return SopCriticality.low;
  // Unknown or empty deliberately lands on medium rather than low: an
  // unlabelled requirement should draw the eye, not disappear down the page.
  return SopCriticality.medium;
}

String criticalityLabel(SopCriticality c) {
  if (c == SopCriticality.high) return 'HIGH';
  if (c == SopCriticality.low) return 'LOW';
  return 'MEDIUM';
}

/// One requirement the document places on the job.
class SopRequirement {
  final String requirement;

  /// Page it came from, or 0 when the model gave none or gave one outside the
  /// scanned range. Zero means "unknown", and the UI must show it as such —
  /// a confidently wrong page number is worse than no page number, because the
  /// whole point of the citation is that a user can go and check.
  final int sourcePage;

  /// The document's own words, as quoted by the model.
  final String sourceText;

  final SopCriticality criticality;

  /// False when [sourceText] could not be found in the OCR text.
  ///
  /// Not a reason to drop the row: OCR damage and legitimate paraphrase both
  /// land here, so dropping would quietly lose real requirements. It IS a reason
  /// to label it, so nobody treats it as a quotation from the approved document.
  final bool verified;

  const SopRequirement({
    required this.requirement,
    this.sourcePage = 0,
    this.sourceText = '',
    this.criticality = SopCriticality.medium,
    this.verified = false,
  });
}

/// One tick box.
class SopCheckItem {
  final String text;

  /// True when the document itself demands this; false when the model is
  /// suggesting it as good practice.
  ///
  /// This single bool is what keeps "Document Requirements" and "AI Suggested
  /// Additional Checks" apart. It must never be inferred at display time.
  final bool fromDocument;

  final int sourcePage;

  const SopCheckItem({
    required this.text,
    required this.fromDocument,
    this.sourcePage = 0,
  });
}

/// A gap or contradiction the model noticed. Never a rewrite of the SOP.
class SopIssue {
  final String issue;
  final String reason;
  final int sourcePage;
  final String sourceText;

  const SopIssue({
    required this.issue,
    required this.reason,
    this.sourcePage = 0,
    this.sourceText = '',
  });
}

class SopSafetyAnalysis {
  final String docType;
  final String activity;
  final String equipment;
  final String riskLevel;

  final List<SopRequirement> hazards;
  final List<SopRequirement> criticalRequirements;

  /// Requirement categories, keyed by the entries of [categories]. Kept as a map
  /// rather than seventeen named fields so a new category is a prompt change and
  /// a list entry, not a model change plus a UI change plus a migration.
  final Map<String, List<String>> requirements;

  final List<SopCheckItem> checklist;
  final List<SopIssue> issues;
  final List<String> aiRecommendations;

  /// True when a model produced this. False means every list is empty and the UI
  /// must say the analysis is unavailable — it must NOT show an empty checklist
  /// as though the document required nothing.
  final bool ok;

  /// True when the document was too long for one pass and the tail was dropped.
  final bool truncated;

  const SopSafetyAnalysis({
    this.docType = '',
    this.activity = '',
    this.equipment = '',
    this.riskLevel = '',
    this.hazards = const [],
    this.criticalRequirements = const [],
    this.requirements = const {},
    this.checklist = const [],
    this.issues = const [],
    this.aiRecommendations = const [],
    this.ok = false,
    this.truncated = false,
  });

  /// Display order for [requirements]. Also the exact key list the prompt asks
  /// for, so the two cannot drift.
  static const List<String> categories = [
    'ppe',
    'permits',
    'isolation',
    'gas_testing',
    'electrical',
    'work_at_height',
    'confined_space',
    'hot_work',
    'lifting',
    'chemical',
    'emergency',
    'competency',
    'pre_job_checks',
    'post_job',
    'prohibited',
  ];

  static const Map<String, String> categoryLabels = {
    'ppe': 'Mandatory PPE',
    'permits': 'Permits required',
    'isolation': 'Isolation / LOTO',
    'gas_testing': 'Gas testing',
    'electrical': 'Electrical safety',
    'work_at_height': 'Work at height',
    'confined_space': 'Confined space',
    'hot_work': 'Hot work',
    'lifting': 'Crane / lifting',
    'chemical': 'Chemical safety',
    'emergency': 'Emergency arrangements',
    'competency': 'Competency / authorisation',
    'pre_job_checks': 'Pre-job checks',
    'post_job': 'Post-job requirements',
    'prohibited': 'Prohibited actions',
  };

  List<String> of(String category) => requirements[category] ?? const [];

  /// Categories that actually have content, in [categories] order.
  List<String> get populatedCategories =>
      categories.where((c) => of(c).isNotEmpty).toList();

  List<SopCheckItem> get documentChecks =>
      checklist.where((c) => c.fromDocument).toList();

  List<SopCheckItem> get suggestedChecks =>
      checklist.where((c) => !c.fromDocument).toList();

  int get highCount => criticalRequirements
      .where((r) => r.criticality == SopCriticality.high)
      .length;

  /// Every requirement whose quoted source text could not be located.
  int get unverifiedCount =>
      criticalRequirements.where((r) => !r.verified).length;
}

class SopSafetyService {
  SopSafetyService._();

  /// The one place the disclaimer text lives.
  ///
  /// A constant rather than a literal in the widget because it has to appear on
  /// the analysis screen, on any export, and in any future share sheet, and
  /// three copies would drift. Wording deliberately says "approved/current" —
  /// a scanned copy on a shop floor is frequently a superseded revision, which
  /// is the realistic failure mode here, not model error.
  static const String disclaimer =
      'AI-assisted analysis only. Always verify requirements against the '
      'approved/current SOP/SMP and site safety procedures before starting '
      'work.';

  /// Input ceiling for one analysis pass.
  ///
  /// Same 60k figure the structuring pass uses, and for the same reason: the
  /// free vision/text models behind this app carry small context windows, and
  /// an over-long prompt comes back as a provider error rather than a truncated
  /// answer. Truncation is reported through [SopSafetyAnalysis.truncated] rather
  /// than hidden, because an analysis of the first 60k characters of a 90k
  /// document is genuinely incomplete and the user has to know that.
  static const int maxInputChars = 60000;

  static const String prompt = '''
The text below was read by OCR from a printed Standard Operating Procedure,
Safe Method of Procedure, Work Instruction or safety instruction at an
integrated steel plant. Page markers show which page each part came from.

You are assisting a safety officer who is about to supervise this job. Return
ONE JSON object and nothing else, with exactly these keys:

{
  "document_type": "SOP | SMP | WI | SAFETY_INSTRUCTION | PERMIT | SIGNAGE | OTHER",
  "activity": "the job this document governs, in the document's words, else \\"\\"",
  "equipment": "equipment, plant or process it applies to, else \\"\\"",
  "risk_level": "HIGH | MEDIUM | LOW — judged from the hazards the document itself names",
  "hazards": [
    {"requirement": "the hazard named in the document", "criticality": "HIGH|MEDIUM|LOW",
     "source_page": 2, "source_text": "the exact words from the document"}
  ],
  "critical_requirements": [
    {"requirement": "a requirement that must be met before or during the job",
     "criticality": "HIGH|MEDIUM|LOW", "source_page": 2,
     "source_text": "the exact words from the document"}
  ],
  "requirements": {
    "ppe": [], "permits": [], "isolation": [], "gas_testing": [],
    "electrical": [], "work_at_height": [], "confined_space": [],
    "hot_work": [], "lifting": [], "chemical": [], "emergency": [],
    "competency": [], "pre_job_checks": [], "post_job": [], "prohibited": []
  },
  "document_checklist": [
    {"text": "a tick box taken from the document", "source_page": 2}
  ],
  "suggested_checklist": [
    {"text": "a tick box that good practice adds and the document does NOT state"}
  ],
  "potential_issues": [
    {"issue": "what may be missing, unclear or contradictory",
     "reason": "why it matters", "source_page": 0, "source_text": ""}
  ],
  "ai_recommendations": ["advice of your own, clearly not from the document"]
}

RULES — these matter more than completeness:
1. A requirement goes in "critical_requirements", "hazards", "requirements" or
   "document_checklist" ONLY if the document states it. If the document does not
   mention gas testing, there is no gas-testing requirement, however obvious it
   seems for this kind of job. Put that thought in "suggested_checklist" or
   "ai_recommendations" instead.
2. "source_text" must be copied from the text below, word for word, not
   paraphrased. It is used to verify the citation. If you cannot quote it, leave
   the whole entry out.
3. "source_page" must be the page marker the quoted words appeared under. Never
   guess a page. Use 0 if you are unsure.
4. Never correct or complete a number, a unit, a permit name, a clause number or
   a standard reference. Copy them as printed, even if they look wrong.
5. Leave a category as [] when the document says nothing about it. An empty list
   is a correct answer and is more useful than a plausible one.
6. If the document is not a safety document at all, say so with
   "document_type": "OTHER" and leave the lists empty.
7. Output raw JSON only — no markdown fence, no preamble, no trailing notes.
''';

  /// Run the analysis over the OCR text of a whole document.
  ///
  /// [pageTexts] is page number -> text, so citations can be verified against
  /// the page the model claims. Never throws: a failure returns
  /// `SopSafetyAnalysis(ok: false)` and the UI reports the analysis as
  /// unavailable.
  static Future<SopSafetyAnalysis> analyse(
    Map<int, String> pageTexts, {
    String title = '',
  }) async {
    if (pageTexts.isEmpty) return const SopSafetyAnalysis();

    final sw = Stopwatch()..start();

    final pages = pageTexts.keys.toList()..sort();
    final joined = pages
        .map((p) => '--- PAGE $p ---\n${pageTexts[p]!.trim()}')
        .join('\n\n');
    final truncated = joined.length > maxInputChars;
    final input = truncated
        ? '${joined.substring(0, maxInputChars)}\n\n[document truncated]'
        : joined;

    final head = title.trim().isEmpty ? '' : 'DOCUMENT TITLE: ${title.trim()}\n';
    final raw = await SopOcrService.askTextModel(
        '$prompt\n\n${head}DOCUMENT TEXT:\n$input');

    if (raw == null) {
      _log(AiRunLog.outcomeFailed, AiRunLog.reasonExhausted, sw);
      return SopSafetyAnalysis(truncated: truncated);
    }

    var parsed = GeminiVision.parseVisionResponse(raw);

    // One repair attempt, and only one. Models that fence or chatter usually
    // comply when told plainly; a model that fails twice is failing for a
    // reason a third ask will not fix, and each attempt costs a request from a
    // free-tier ledger the hazard scan also draws on.
    if (parsed == null) {
      print('SopSafety: first response was not JSON, asking for a repair');
      final retry = await SopOcrService.askTextModel(
          'Your previous reply was not valid JSON. Return the SAME content as '
          'ONE raw JSON object with no markdown fence and no commentary.\n\n'
          'PREVIOUS REPLY:\n$raw');
      if (retry != null) parsed = GeminiVision.parseVisionResponse(retry);
    }

    if (parsed == null) {
      _log(AiRunLog.outcomeFailed, AiRunLog.reasonEmptyResult, sw);
      return SopSafetyAnalysis(truncated: truncated);
    }

    final maxPage = pages.isEmpty ? 0 : pages.last;
    final haystack = _normalise(joined);

    final hazards = _requirements(parsed['hazards'], maxPage, haystack);
    final critical =
        _requirements(parsed['critical_requirements'], maxPage, haystack);

    final reqs = <String, List<String>>{};
    final rawReqs = parsed['requirements'];
    if (rawReqs is Map) {
      for (final key in SopSafetyAnalysis.categories) {
        final list = _stringList(rawReqs[key]);
        if (list.isNotEmpty) reqs[key] = list;
      }
    }

    final checklist = <SopCheckItem>[
      ..._checks(parsed['document_checklist'], maxPage, fromDocument: true),
      ..._checks(parsed['suggested_checklist'], maxPage, fromDocument: false),
    ];

    _log(AiRunLog.outcomeSuccess, '', sw);

    return SopSafetyAnalysis(
      docType: _str(parsed['document_type']),
      activity: _str(parsed['activity']),
      equipment: _str(parsed['equipment']),
      riskLevel: _riskLevel(_str(parsed['risk_level']), critical),
      hazards: hazards,
      criticalRequirements: critical,
      requirements: reqs,
      checklist: checklist,
      issues: _issues(parsed['potential_issues'], maxPage),
      aiRecommendations: _stringList(parsed['ai_recommendations']),
      ok: true,
      truncated: truncated,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Validation
  // ═══════════════════════════════════════════════════════════════════════

  static String _str(dynamic v) => v?.toString().trim() ?? '';

  static List<String> _stringList(dynamic v) {
    if (v is! List) return const [];
    final out = <String>[];
    for (final e in v) {
      // Accept {"text": "..."} as well as a bare string: models drift between
      // the two across runs of the same prompt, and rejecting one shape loses a
      // whole category for no reason the user could act on.
      final s = e is Map ? _str(e['text'] ?? e['requirement']) : _str(e);
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  /// Clamp a claimed page to the range that was actually scanned.
  ///
  /// Out-of-range becomes 0 ("unknown") rather than the nearest real page. A
  /// citation that points at the wrong page is worse than one that admits it
  /// does not know, because the user checks page 3, does not find the line, and
  /// stops trusting every other citation on the screen.
  static int _page(dynamic v, int maxPage) {
    final n = int.tryParse(_str(v)) ?? 0;
    if (n < 1 || n > maxPage) return 0;
    return n;
  }

  static List<SopRequirement> _requirements(
      dynamic v, int maxPage, String haystack) {
    if (v is! List) return const [];
    final out = <SopRequirement>[];
    for (final e in v) {
      if (e is! Map) continue;
      final text = _str(e['requirement']);
      if (text.isEmpty) continue;
      final src = _str(e['source_text']);
      out.add(SopRequirement(
        requirement: text,
        sourcePage: _page(e['source_page'], maxPage),
        sourceText: src,
        criticality: _criticalityOf(_str(e['criticality'])),
        verified: _verify(src, haystack),
      ));
    }
    return out;
  }

  static List<SopCheckItem> _checks(dynamic v, int maxPage,
      {required bool fromDocument}) {
    if (v is! List) return const [];
    final out = <SopCheckItem>[];
    for (final e in v) {
      final text = e is Map ? _str(e['text']) : _str(e);
      if (text.isEmpty) continue;
      out.add(SopCheckItem(
        text: text,
        fromDocument: fromDocument,
        sourcePage: e is Map ? _page(e['source_page'], maxPage) : 0,
      ));
    }
    return out;
  }

  static List<SopIssue> _issues(dynamic v, int maxPage) {
    if (v is! List) return const [];
    final out = <SopIssue>[];
    for (final e in v) {
      if (e is! Map) continue;
      final issue = _str(e['issue']);
      if (issue.isEmpty) continue;
      out.add(SopIssue(
        issue: issue,
        reason: _str(e['reason']),
        sourcePage: _page(e['source_page'], maxPage),
        sourceText: _str(e['source_text']),
      ));
    }
    return out;
  }

  /// Is this quotation actually in the document?
  ///
  /// The check is deliberately lenient about form and strict about substance:
  /// case, punctuation and whitespace are stripped before comparing, because OCR
  /// and the model will differ on all three for text that is genuinely the same.
  /// What it will not forgive is words that are not there.
  ///
  /// Only the first [_verifyWindow] characters are matched. A long quotation
  /// almost always contains one OCR-mangled character somewhere, and requiring
  /// the whole span to match would mark nearly everything unverified, which
  /// destroys the signal — a flag that fires on every row tells the reader
  /// nothing.
  static bool _verify(String sourceText, String haystack) {
    final needle = _normalise(sourceText);
    if (needle.length < 12) return false; // too short to prove anything
    final probe = needle.length <= _verifyWindow
        ? needle
        : needle.substring(0, _verifyWindow);
    return haystack.contains(probe);
  }

  static const int _verifyWindow = 40;

  /// Strip everything that is not a letter, digit or Devanagari character.
  ///
  /// The Devanagari block U+0900..U+097F is kept so a Hindi SOP verifies the same
  /// way an English one does — without it, every Hindi quotation normalises to an
  /// empty string, fails the length test and is reported unverified.
  ///
  /// Written as \\u escapes in a NON-raw string on purpose: inside r'...' the
  /// escapes stay literal characters and the class matches the letters u, 0, 9
  /// instead of the block. Literal Devanagari glyphs here would be worse still —
  /// one editor re-encoding the file silently changes what the regex matches.
  static String _normalise(String s) =>
      s.toLowerCase().replaceAll(RegExp('[^a-z0-9\\u0900-\\u097F]'), '');

  /// Trust the model's risk level, but never let it under-call its own findings.
  ///
  /// A model that lists three HIGH-criticality requirements and then reports
  /// "risk_level": "LOW" has contradicted itself, and on a safety screen the
  /// safe reading of a contradiction is the more serious one.
  static String _riskLevel(String claimed, List<SopRequirement> critical) {
    final hasHigh =
        critical.any((r) => r.criticality == SopCriticality.high);
    final c = claimed.trim().toUpperCase();
    if (hasHigh) return 'HIGH';
    if (c == 'HIGH' || c == 'MEDIUM' || c == 'LOW') return c;
    return critical.isEmpty ? '' : 'MEDIUM';
  }

  static void _log(String outcome, String reason, Stopwatch sw) {
    AiRunLog.record(
      runType: AiRunLog.typeSopSafety,
      outcome: outcome,
      failReason: reason,
      durationMs: sw.elapsedMilliseconds,
    );
  }
}
