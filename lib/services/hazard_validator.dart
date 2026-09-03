import 'package:flutter/foundation.dart' show debugPrint;

import 'admin_master_data.dart';
import 'hazard_confidence.dart';
import 'local_db.dart';
import 'regulation_catalog.dart';

/// Post-hoc validation of AI hazard findings against everything the app already
/// knows.
///
/// WHY THIS EXISTS
/// ---------------
/// Until now the knowledge base was used in ONE direction only: it was pulled
/// into the prompt before the scan and never looked at again. Whatever came back
/// was trusted completely. Nothing checked that a cited section number existed,
/// that it had anything to do with the hazard described, that the severity label
/// was one the app's own dropdowns use, or that the "REQUIRED" visual evidence
/// had actually been supplied. A confident-sounding invention and a
/// well-evidenced observation were rendered identically, and both flowed into an
/// official observation record and its PDF.
///
/// Confidence was also reported once per REPORT. One number covering seven
/// findings tells a safety officer nothing about which of the seven to trust.
///
/// This service closes both gaps. It never deletes a hazard — see [validate].
class HazardValidator {
  HazardValidator._();

  /// Marker written onto a validated result, so validation is idempotent and a
  /// cached report from an older build is recognisable as un-validated.
  static const String kValidatedFlag = '_validated';

  /// Raw keyword score from [LocalDB.searchKnowledge] at which a knowledge-base
  /// hit counts as genuine corroboration rather than an incidental word match.
  ///
  /// The scorer gives +5 for a title hit and +10 for a full-phrase hit on top of
  /// per-word counts, so this sits just above "one or two words happened to
  /// appear" and below "the title or a whole phrase matched".
  static const int kCorroborationScore = 8;

  /// Hedging language that makes an "evidence" field worthless. A hazard whose
  /// proof is "commonly found in such areas" is an assumption wearing the
  /// costume of an observation, which is more misleading than leaving the field
  /// empty.
  static final RegExp _genericEvidence = RegExp(
    r'\b(typical|typically|commonly|usually|generally|often|may be|might be|'
    r'could be|not (?:clearly )?visible|cannot be seen|assumed|assuming|'
    r'presumably|likely present|standard practice|in such|no specific)\b',
    caseSensitive: false,
  );

  /// Wording that could be pasted onto any steel-plant photograph without
  /// changing a word. Distinct from [_genericEvidence], which catches hedging
  /// ("typically", "commonly") — this catches a finding that is not hedged at
  /// all, simply empty. "PPE not worn — risk of injury" asserts something
  /// definite about nothing in particular, and a safety officer cannot act on it
  /// because it names no object, no place and no deviation.
  ///
  /// Matched against name + description ONLY, never against the evidence field:
  /// a hazard may legitimately be *called* "Missing guardrail" as long as the
  /// description and evidence locate it.
  static final RegExp _boilerplateFinding = RegExp(
    r'\b(?:ppe (?:not|non).?(?:worn|compliance)|unsafe (?:condition|act) '
    r'(?:observed|noted|present)|safety (?:violation|hazard) (?:observed|noted)|'
    r'improper (?:use|handling)|lack of (?:safety|proper) \w+|'
    r'general housekeeping issue|potential (?:risk|hazard) (?:of|to) \w+|'
    r'risk of (?:injury|accident|harm)\.?$|not following (?:safety )?procedure)\b',
    caseSensitive: false,
  );

  /// Words carried by [_inventoryTokens] that say nothing about what is in a
  /// photograph, so their presence in both fields is not corroboration.
  static const Set<String> _stopWords = {
    'the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to', 'is', 'are',
    'was', 'were', 'be', 'being', 'been', 'with', 'without', 'for', 'from',
    'this', 'that', 'these', 'those', 'it', 'its', 'as', 'by', 'near', 'no',
    'not', 'has', 'have', 'there', 'visible', 'seen', 'see', 'image', 'photo',
    'photograph', 'frame', 'view', 'shows', 'showing', 'left', 'right',
    'centre', 'center', 'foreground', 'background', 'middle', 'front', 'behind',
    'side', 'area', 'zone', 'region', 'part', 'which', 'while', 'where',
  };

  /// Content words of [text], lowercased and crudely de-pluralised.
  ///
  /// Crude on purpose. This feeds a check that only fires on ZERO overlap (see
  /// [_evidenceUngrounded]), so over-matching costs nothing and under-matching
  /// would produce false accusations against correct findings.
  static Set<String> _inventoryTokens(String text) {
    final out = <String>{};
    for (final raw in text.toLowerCase().split(RegExp(r'[^a-z]+'))) {
      if (raw.length < 4 || _stopWords.contains(raw)) continue;
      out.add(raw.endsWith('s') && raw.length > 4
          ? raw.substring(0, raw.length - 1)
          : raw);
    }
    return out;
  }

  /// True when a hazard's stated visual evidence names nothing that appears in
  /// the model's own scene inventory.
  ///
  /// WHY THIS IS WORTH CHECKING
  /// The prompt now asks the model to write what it can see BEFORE judging any
  /// of it, and to report only hazards concerning something it inventoried. That
  /// gives the app a self-consistency check inside a single response, at no
  /// extra cost and with no second call: evidence citing an object the model
  /// never listed is the signature of a hazard recalled from training data
  /// rather than read off this photograph.
  ///
  /// It is deliberately the weakest possible form of the test. It fires only
  /// when the overlap is EMPTY and the evidence carried at least three content
  /// words to begin with. A partial mismatch — evidence naming one object that
  /// was inventoried and one that was not — does not fire, because a model
  /// describing a real hazard often names a part ("chin strap") whose parent
  /// ("worker") is what it inventoried. Returns null when the model gave no
  /// inventory at all, which is the honest answer for a tier or a build that
  /// never asked for one; a missing inventory must not read as a failed check.
  static bool? _evidenceUngrounded(String evidence, Set<String>? inventory) {
    if (inventory == null || inventory.isEmpty) return null;
    final cited = _inventoryTokens(evidence);
    if (cited.length < 3) return null;
    return cited.intersection(inventory).isEmpty;
  }

  /// Validates every hazard in [result] in place and returns the same map.
  ///
  /// Hazards are NEVER removed, however poorly they score. A false positive
  /// costs a safety officer a few seconds of reading; a hazard silently deleted
  /// because the app could not corroborate it costs whatever the hazard goes on
  /// to cause. Low scores are labelled, not acted upon — the human decides.
  ///
  /// Never throws. A validation failure must degrade to an unvalidated report,
  /// because the scan itself is still useful and the worker is standing in front
  /// of the hazard right now.
  static Future<Map<String, dynamic>> validate(
    Map<String, dynamic> result, {
    bool force = false,
  }) async {
    try {
      if (result[kValidatedFlag] == true && !force) return result;

      final hazards = result['hazards'];
      if (hazards is! List || hazards.isEmpty) {
        result[kValidatedFlag] = true;
        return result;
      }

      final reportConfidence = _asInt(result['confidence']);

      // Tokenised once for the whole report rather than per hazard. Null when
      // the model returned no inventory, which disables the grounding check
      // rather than failing it — see [_evidenceUngrounded].
      final inventoryText = _str(result['sceneInventory']);
      final Set<String>? inventory =
          inventoryText.trim().length < 12 ? null : _inventoryTokens(inventoryText);

      // Master data, each independently guarded: an admin list failing to load
      // must not turn every hazard into a vocabulary complaint.
      final severities = await _safeList(
          AdminMasterData.getSeverities, AdminMasterData.defaultSeverities);
      final obsTypes = await _safeList(AdminMasterData.getObsTypes,
          AdminMasterData.defaultObservationTypes);
      final wsaCauses = await _safeList(
          AdminMasterData.getWsaCauses, AdminMasterData.defaultWsaCauses);

      final sevSet = severities.map(_norm).toSet();
      final typeSet = obsTypes.map(_norm).toSet()..add(_norm('Line of Fire'));
      // WSA causes arrive numbered ("1. Failure to follow procedure") but models
      // routinely drop the number, so compare on the text alone.
      final wsaSet = wsaCauses.map((c) => _norm(_stripLeadingNumber(c))).toSet();

      int verifiedCitations = 0;
      int reviewCount = 0;
      int confidenceSum = 0;
      int scored = 0;

      for (final raw in hazards) {
        if (raw is! Map) continue;
        final h = raw.cast<String, dynamic>();

        final name = _str(h['name']);
        final description = _str(h['description']);
        final evidence = _str(h['visualEvidence']);
        final action = _str(h['correctiveAction']);
        final citation = _str(h['regulation']);
        final subjectText = '$name $description $evidence $action';

        // ── Citation ────────────────────────────────────────────────────────
        final banned = citation.isNotEmpty
            ? RegulationCatalog.bannedReason(citation)
            : null;
        final entry =
            citation.isEmpty ? null : RegulationCatalog.lookup(citation);
        String? misapplied;
        bool? fit;
        if (entry != null) {
          misapplied = RegulationCatalog.misapplication(entry, subjectText);
          fit = RegulationCatalog.topicalFit(entry, subjectText);
        }

        // The catalogue is not the whole story: a plant uploads its own SOPs and
        // standards, and the prompt explicitly tells the model those are
        // citable. So a citation absent from the catalogue is checked against
        // the knowledge base before being called unverifiable.
        bool inKb = false;
        String kbSource = '';
        if (entry == null && banned == null && citation.isNotEmpty) {
          final hits = await _searchKb(citation, limit: 2);
          for (final hit in hits) {
            final haystack =
                '${hit['title'] ?? ''} ${hit['snippet'] ?? ''} '
                '${hit['sopNumber'] ?? ''} ${hit['clauseNo'] ?? ''}';
            if (_citationAppearsIn(citation, haystack)) {
              inKb = true;
              kbSource = _str(hit['title']);
              break;
            }
          }
        }

        // ── Independent corroboration of the hazard itself ──────────────────
        bool corroborated = false;
        String corroborationSource = '';
        if (name.isNotEmpty) {
          final hits = await _searchKb(name, limit: 1);
          if (hits.isNotEmpty &&
              _asInt(hits.first['score']) != null &&
              _asInt(hits.first['score'])! >= kCorroborationScore) {
            corroborated = true;
            corroborationSource = _str(hits.first['title']);
          }
        }

        // ── Evidence, vocabulary, geometry ─────────────────────────────────
        final hasEvidence = evidence.trim().length >= 8;
        final genericEvidence = hasEvidence &&
            (_genericEvidence.hasMatch(evidence) ||
                _genericEvidence.hasMatch(description));
        final severity = _str(h['severity']);
        final type = _str(h['type']);
        final wsaCause = _str(h['wsaCause']);

        // Self-consistency against the model's own scene inventory, and the
        // vagueness test. Both are computed here so they land in the same
        // itemised confidence reasons as every other signal.
        final ungrounded = _evidenceUngrounded(evidence, inventory);
        final boilerplate = _boilerplateFinding.hasMatch('$name $description');

        final signals = HazardSignals(
          modelConfidence: _asInt(h['confidence']),
          reportConfidence: reportConfidence,
          hasVisualEvidence: hasEvidence,
          evidenceLooksGeneric: genericEvidence,
          descriptionStartsWithVisible:
              description.trimLeft().toLowerCase().startsWith('visible'),
          citationPresent: citation.isNotEmpty,
          citationInCatalogue: entry != null && banned == null,
          citationInKnowledgeBase: inKb,
          citationBanned: banned != null,
          citationMisapplied: misapplied != null,
          topicalFit: fit,
          kbCorroborated: corroborated,
          severityKnown: severity.isEmpty || sevSet.contains(_norm(severity)),
          typeKnown: type.isEmpty || typeSet.contains(_norm(type)),
          wsaCauseKnown: wsaCause.isEmpty
              ? null
              : wsaSet.contains(_norm(_stripLeadingNumber(wsaCause))),
          hasUsableBbox: _hasUsableBbox(h['bbox']),
          evidenceUngrounded: ungrounded,
          findingIsBoilerplate: boilerplate,
        );

        final outcome = HazardConfidence.score(signals);
        final needsReview =
            HazardConfidence.needsReview(outcome.confidence, signals);

        // The model's original number is preserved rather than overwritten, so
        // the adjustment stays auditable and AiCorrectionService can still see
        // what the model actually claimed.
        h['modelConfidence'] = signals.modelConfidence;
        h['confidence'] = outcome.confidence;
        h['confidenceBasis'] = outcome.basis;
        h['confidenceReasons'] =
            outcome.reasons.map((r) => r.toJson()).toList();
        h['needsReview'] = needsReview;
        h['regulationVerified'] = signals.citationInCatalogue || inKb;
        h['regulationVerifiedBy'] = signals.citationInCatalogue
            ? 'catalogue'
            : (inKb ? 'knowledge base' : '');
        if (kbSource.isNotEmpty) h['regulationSource'] = kbSource;
        final issue = banned ?? misapplied;
        if (issue != null) {
          h['regulationIssue'] = issue;
        } else {
          h.remove('regulationIssue');
        }
        if (corroborated) h['kbCorroboration'] = corroborationSource;

        if (h['regulationVerified'] == true) verifiedCitations++;
        if (needsReview) reviewCount++;
        confidenceSum += outcome.confidence;
        scored++;
      }

      // Report-level roll-up. The existing top-level 'confidence' is left
      // untouched on purpose: it is recorded in AiRunLog and averaged on the
      // admin dashboard, so redefining it would silently change the meaning of
      // historical telemetry.
      result['validation'] = {
        'hazards': scored,
        'citationsVerified': verifiedCitations,
        'needsReview': reviewCount,
        'meanConfidence': scored == 0 ? 0 : (confidenceSum / scored).round(),
      };
      result[kValidatedFlag] = true;
      return result;
    } catch (e, st) {
      debugPrint('HazardValidator: validation failed — $e\n$st');
      // Deliberately NOT marked validated, so the UI can tell the difference
      // between "checked and clean" and "never checked".
      return result;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Knowledge-base search that can never break or stall a scan.
  static Future<List<Map<String, dynamic>>> _searchKb(String query,
      {int limit = 2}) async {
    try {
      return await LocalDB
          .searchKnowledge(query, limit: limit, snippetChars: 300)
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('HazardValidator: KB search failed for "$query" — $e');
      return const [];
    }
  }

  /// Whether [citation] genuinely appears in [haystack], compared on signature
  /// rather than as a substring, so "S21" cannot be satisfied by "S210" and
  /// "Section 21" matches "S21".
  static bool _citationAppearsIn(String citation, String haystack) {
    final want = RegulationCatalog.signature(citation);
    if (want.isEmpty) return false;
    // Scan the haystack in overlapping windows: a signature needs both the
    // instrument and the clause, which are usually a few words apart.
    final words = haystack.split(RegExp(r'\s+'));
    for (int i = 0; i < words.length; i++) {
      final window = words.skip(i).take(8).join(' ');
      if (RegulationCatalog.signature(window) == want) return true;
    }
    return false;
  }

  static bool _hasUsableBbox(dynamic bbox) {
    if (bbox is! Map) return false;
    final w = _asDouble(bbox['w']);
    final h = _asDouble(bbox['h']);
    return w != null && h != null && w > 0.01 && h > 0.01;
  }

  static Future<List<String>> _safeList(
      Future<List<String>> Function() load, List<String> fallback) async {
    try {
      final v = await load();
      return v.isEmpty ? List<String>.from(fallback) : v;
    } catch (_) {
      return List<String>.from(fallback);
    }
  }

  static String _stripLeadingNumber(String s) =>
      s.replaceFirst(RegExp(r'^\s*\d+\s*[.)-]?\s*'), '');

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static String _str(dynamic v) => v == null ? '' : v.toString().trim();

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v?.toString() ?? '');
  }

  static double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '');
  }
}
