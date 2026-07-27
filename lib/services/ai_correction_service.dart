// lib/services/ai_correction_service.dart
// ★ AI Correction Feedback Loop — SAIL Safety Lens
//
// PURPOSE
//   Capture every edit a user makes to AI-generated output (summary, severity,
//   corrective action) after a hazard scan or near-miss analysis, so an admin
//   can later review each one and decide:
//       • "AI mistake"       → the model got it wrong. The corrected version is
//                              fed into the fine-tuning dataset so the AI keeps
//                              improving and accuracy climbs over time.
//       • "User preference"  → the AI was fine; the user just reworded it. No
//                              training impact.
//
//   This is the trust-building loop: users see their corrections matter, and
//   the model measurably improves on the mistakes real inspectors catch.
//
// DESIGN
//   • Offline-first. Every correction is written to LocalDB immediately, then
//     mirrored to Supabase (table `ai_corrections`) when the backend is ready.
//   • The admin panel reads getAllCorrections(), which merges the Supabase
//     view (cross-device) with the local queue (offline / not-yet-synced).
//   • No-op safe: if Supabase is disabled, everything still works locally.

import 'dart:convert';
import 'local_db.dart';
import 'supabase_service.dart';
import 'fine_tuning_collector.dart';
import 'app_logger.dart';

class AiCorrectionService {
  AiCorrectionService._();

  // Verdict constants.
  static const String verdictPending        = 'pending';
  static const String verdictAiMistake       = 'ai_mistake';
  static const String verdictUserPreference  = 'user_preference';

  // Field-changed constants.
  static const String fieldSummary          = 'summary';
  static const String fieldOverallRisk       = 'overallRisk';
  static const String fieldSeverity          = 'severity';
  static const String fieldCorrectiveAction  = 'correctiveAction';
  static const String fieldHazardSeverity    = 'hazardSeverity';
  // ★ A hazard the AI detected but the user removed = a false positive. This is
  //   an unambiguous AI mistake (the hazard wasn't in the picture), so it is
  //   auto-classified and fed to training without waiting for admin review.
  static const String fieldHazardDeleted     = 'hazardDeleted';
  // ★ A hazard the user added that the AI missed = a false negative. Recorded
  //   for admin review (could be a real miss worth training on).
  static const String fieldHazardAdded       = 'hazardAdded';

  /// Sentinel stored in editedValue for a deleted hazard — tells the training
  /// exporter "the model should NOT have flagged this hazard for this image".
  static const String valueHazardNotPresent  = 'HAZARD_NOT_PRESENT';

  // ══════════════════════════════════════════════════════════════════════════
  //  RECORDING EDITS
  // ══════════════════════════════════════════════════════════════════════════

  /// Diff an AI result against the user-edited version and record one
  /// correction per changed field. Call this on "Save with edits".
  ///
  /// [original] and [edited] are the AI result maps (with keys like
  /// 'summary', 'overallRisk', and a 'hazards' list). Only the fields the
  /// admin cares about are compared: summary, overall severity/risk, and
  /// per-hazard severity + corrective action.
  static Future<int> recordResultEdits({
    required String incidentId,
    required String incidentType, // 'AI_SCAN' | 'NEAR_MISS'
    required Map<String, dynamic> original,
    required Map<String, dynamic> edited,
    String imageHash = '',
    String plant = '',
    String editedBy = '',
    String aiSource = '',
    String imageBase64 = '', // enables auto-training for deleted hazards
  }) async {
    var recorded = 0;

    // ── Summary ──────────────────────────────────────────────────────────
    final origSummary = (original['summary'] ?? '').toString().trim();
    final editSummary = (edited['summary'] ?? '').toString().trim();
    if (origSummary != editSummary) {
      await _record(
        incidentId: incidentId, incidentType: incidentType,
        field: fieldSummary, original: origSummary, edited: editSummary,
        imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
      );
      recorded++;
    }

    // ── Overall risk / severity ──────────────────────────────────────────
    final origRisk = (original['overallRisk'] ?? original['severity'] ?? '')
        .toString().trim().toUpperCase();
    final editRisk = (edited['overallRisk'] ?? edited['severity'] ?? '')
        .toString().trim().toUpperCase();
    if (origRisk.isNotEmpty && origRisk != editRisk) {
      await _record(
        incidentId: incidentId, incidentType: incidentType,
        field: fieldOverallRisk, original: origRisk, edited: editRisk,
        imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
      );
      recorded++;
    }

    // ── Per-hazard diff ──────────────────────────────────────────────────
    // CRITICAL: match hazards by NAME, not by list position. If we matched by
    // index, deleting a hazard from the middle would shift every later hazard
    // up one slot and be misread as a flurry of "severity"/"corrective action"
    // edits on the wrong hazards — while the actual deletion went unrecorded.
    final origHaz = _hazardList(original['hazards']);
    final editHaz = _hazardList(edited['hazards']);

    String nameKey(Map<String, dynamic> h) =>
        (h['name'] ?? '').toString().trim().toLowerCase();

    final editByName = <String, Map<String, dynamic>>{};
    for (final e in editHaz) {
      final k = nameKey(e);
      if (k.isNotEmpty) editByName[k] = e;
    }
    final origByName = <String, Map<String, dynamic>>{};
    for (final o in origHaz) {
      final k = nameKey(o);
      if (k.isNotEmpty) origByName[k] = o;
    }

    // 1) Hazards the AI produced but the user removed → false positive.
    //    Auto-classified as an AI mistake and (if we have the image) fed to
    //    training immediately, so a deletion is itself the feedback signal.
    for (final o in origHaz) {
      final k = nameKey(o);
      if (k.isEmpty || editByName.containsKey(k)) continue;
      final hazardName = (o['name'] ?? 'Hazard').toString();
      await _record(
        incidentId: incidentId, incidentType: incidentType,
        field: fieldHazardDeleted,
        original: hazardName,          // what the AI wrongly flagged
        edited: valueHazardNotPresent, // the correct label: not present
        hazardName: hazardName,
        imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
        autoVerdict: verdictAiMistake, // deletion = unambiguous AI mistake
        imageBase64: imageBase64,
      );
      recorded++;
    }

    // 2) Hazards the user added that the AI missed → false negative (review).
    for (final e in editHaz) {
      final k = nameKey(e);
      if (k.isEmpty || origByName.containsKey(k)) continue;
      final hazardName = (e['name'] ?? 'Hazard').toString();
      await _record(
        incidentId: incidentId, incidentType: incidentType,
        field: fieldHazardAdded,
        original: '', edited: hazardName,
        hazardName: hazardName,
        imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
      );
      recorded++;
    }

    // 3) Hazards present in BOTH → compare severity + corrective action only.
    for (final e in editHaz) {
      final k = nameKey(e);
      final o = origByName[k];
      if (o == null) continue; // added hazard, already handled above
      final hazardName = (e['name'] ?? o['name'] ?? 'Hazard').toString();

      final oSev = (o['severity'] ?? '').toString().trim().toUpperCase();
      final eSev = (e['severity'] ?? '').toString().trim().toUpperCase();
      if (oSev.isNotEmpty && oSev != eSev) {
        await _record(
          incidentId: incidentId, incidentType: incidentType,
          field: fieldHazardSeverity, original: oSev, edited: eSev,
          hazardName: hazardName,
          imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
        );
        recorded++;
      }

      final oCa = (o['correctiveAction'] ?? '').toString().trim();
      final eCa = (e['correctiveAction'] ?? '').toString().trim();
      if (oCa != eCa) {
        await _record(
          incidentId: incidentId, incidentType: incidentType,
          field: fieldCorrectiveAction, original: oCa, edited: eCa,
          hazardName: hazardName,
          imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
        );
        recorded++;
      }
    }

    if (recorded > 0) {
      AppLogger.info('AiCorrection', 'Recorded $recorded edit(s) for $incidentId');
    }
    return recorded;
  }

  /// Record a single field-level correction (summary/severity/action edit made
  /// somewhere other than the multi-field diff, e.g. the near-miss form).
  static Future<void> recordSingleEdit({
    required String incidentId,
    required String incidentType,
    required String field,
    required String original,
    required String edited,
    String hazardName = '',
    String imageHash = '',
    String plant = '',
    String editedBy = '',
    String aiSource = '',
  }) async {
    if (original.trim() == edited.trim()) return;
    await _record(
      incidentId: incidentId, incidentType: incidentType,
      field: field, original: original.trim(), edited: edited.trim(),
      hazardName: hazardName,
      imageHash: imageHash, plant: plant, editedBy: editedBy, aiSource: aiSource,
    );
  }

  static Future<void> _record({
    required String incidentId,
    required String incidentType,
    required String field,
    required String original,
    required String edited,
    String hazardName = '',
    String imageHash = '',
    String plant = '',
    String editedBy = '',
    String aiSource = '',
    String autoVerdict = verdictPending, // pre-classify (e.g. deletions)
    String imageBase64 = '',             // enables immediate auto-training
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}_${field}_$incidentId';
    final now = DateTime.now().toIso8601String();
    final isAuto = autoVerdict != verdictPending;
    final record = <String, dynamic>{
      'id': id,
      'incidentId': incidentId,
      'incidentType': incidentType,
      'imageHash': imageHash,
      'plant': plant,
      'fieldChanged': field,
      'hazardName': hazardName,
      'originalValue': original,
      'editedValue': edited,
      'editedBy': editedBy,
      'aiSource': aiSource,
      'verdict': autoVerdict,
      // Auto-classified corrections are system-reviewed, not admin-reviewed.
      'reviewedBy': isAuto ? 'auto (hazard removed)' : '',
      'reviewedAt': isAuto ? now : null,
      'addedToTraining': false,
      'createdAt': now,
    };

    // Auto-feed training for a removed hazard (false positive). We have the
    // image, so the model can learn "don't flag <hazard> for this image."
    if (autoVerdict == verdictAiMistake && imageBase64.isNotEmpty) {
      try {
        final ok = await FineTuningCollector.saveTrainingExample(
          imageBase64: imageBase64,
          approvedResult: {
            'correctionField': field,
            'hazardName': hazardName,
            'correctedValue': edited,   // HAZARD_NOT_PRESENT
            'originalValue': original,  // the wrongly-flagged hazard name
            'detectedSection': plant,
          },
          metadata: {
            'source': 'ai_correction_auto',
            'incidentId': incidentId,
            'field': field,
            'reviewedBy': 'auto',
          },
        );
        record['addedToTraining'] = ok;
      } catch (_) {}
    }

    // 1) Local first (never lose an edit).
    await LocalDB.saveAiCorrection(record);
    // 2) Best-effort mirror to Supabase (no-op if disabled/offline).
    try {
      await SupabaseService.upsertCorrection(record);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  READING (for the admin review panel)
  // ══════════════════════════════════════════════════════════════════════════

  /// All corrections, newest first. Merges the Supabase view (cross-device)
  /// with the local queue so nothing is missed whether online or offline.
  static Future<List<Map<String, dynamic>>> getAllCorrections() async {
    // Best-effort remote sync — never let a slow/failed Supabase call block the
    // admin panel. On any error (missing table, no network, timeout) we simply
    // fall back to whatever is in the local store.
    try {
      final remote = await SupabaseService.fetchCorrections()
          .timeout(const Duration(seconds: 10), onTimeout: () => const []);
      if (remote.isNotEmpty) {
        // Keep the local store in sync so offline admin still sees them.
        await LocalDB.mergeAiCorrections(remote);
      }
    } catch (_) {
      // Ignore — local data is the source of truth for display.
    }
    final all = await LocalDB.getAiCorrections();
    all.sort((a, b) => (b['createdAt']?.toString() ?? '')
        .compareTo(a['createdAt']?.toString() ?? ''));
    return all;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  ADMIN VERDICTS
  // ══════════════════════════════════════════════════════════════════════════

  /// Mark a correction as an AI mistake. The user-corrected value becomes a
  /// training signal: we push a compact example into FineTuningCollector so it
  /// is included in the next JSONL export for Gemini fine-tuning.
  ///
  /// [imageBase64] is the evidence photo for this incident, if available — it
  /// makes the training example far more useful (vision fine-tuning). If it's
  /// empty we still record the verdict; the training push is skipped.
  static Future<void> markAiMistake(
    Map<String, dynamic> correction, {
    required String reviewedBy,
    String imageBase64 = '',
  }) async {
    final updated = <String, dynamic>{
      ...correction,
      'verdict': verdictAiMistake,
      'reviewedBy': reviewedBy,
      'reviewedAt': DateTime.now().toIso8601String(),
    };

    // Feed the correction into the fine-tuning dataset (only if we have the
    // image and haven't already added this one).
    final already = correction['addedToTraining'] == true;
    if (!already && imageBase64.isNotEmpty) {
      final ok = await FineTuningCollector.saveTrainingExample(
        imageBase64: imageBase64,
        approvedResult: {
          'correctionField': correction['fieldChanged'],
          'hazardName': correction['hazardName'],
          // The value the inspector says is correct — what the model should learn.
          'correctedValue': correction['editedValue'],
          'originalValue': correction['originalValue'],
          'detectedSection': correction['plant'],
        },
        metadata: {
          'source': 'ai_correction',
          'incidentId': correction['incidentId']?.toString() ?? '',
          'field': correction['fieldChanged']?.toString() ?? '',
          'reviewedBy': reviewedBy,
        },
      );
      updated['addedToTraining'] = ok;
    }

    await LocalDB.saveAiCorrection(updated);
    try {
      await SupabaseService.upsertCorrection(updated);
    } catch (_) {}
  }

  /// Mark a correction as a user preference (AI was fine). Records the verdict
  /// only — no training impact.
  static Future<void> markUserPreference(
    Map<String, dynamic> correction, {
    required String reviewedBy,
  }) async {
    final updated = <String, dynamic>{
      ...correction,
      'verdict': verdictUserPreference,
      'reviewedBy': reviewedBy,
      'reviewedAt': DateTime.now().toIso8601String(),
    };
    await LocalDB.saveAiCorrection(updated);
    try {
      await SupabaseService.upsertCorrection(updated);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  STATS (for the trust dashboard header)
  // ══════════════════════════════════════════════════════════════════════════

  static Map<String, dynamic> computeStats(
      List<Map<String, dynamic>> corrections) {
    final total = corrections.length;
    var pending = 0, aiMistake = 0, userPref = 0, addedToTraining = 0;
    final fieldMistakes = <String, int>{};

    for (final c in corrections) {
      final v = c['verdict']?.toString() ?? verdictPending;
      if (v == verdictAiMistake) {
        aiMistake++;
        final f = c['fieldChanged']?.toString() ?? 'other';
        fieldMistakes[f] = (fieldMistakes[f] ?? 0) + 1;
      } else if (v == verdictUserPreference) {
        userPref++;
      } else {
        pending++;
      }
      if (c['addedToTraining'] == true) addedToTraining++;
    }

    final reviewed = aiMistake + userPref;
    final aiMistakeRate = reviewed > 0 ? (aiMistake / reviewed * 100) : 0.0;

    // The field the AI gets wrong most often (of reviewed AI mistakes).
    String topMistakeField = '—';
    var topCount = 0;
    fieldMistakes.forEach((f, n) {
      if (n > topCount) { topCount = n; topMistakeField = f; }
    });

    return {
      'total': total,
      'pending': pending,
      'aiMistake': aiMistake,
      'userPreference': userPref,
      'addedToTraining': addedToTraining,
      'aiMistakeRate': aiMistakeRate,
      'fieldMistakes': fieldMistakes,
      'topMistakeField': topMistakeField,
    };
  }

  // ── helpers ────────────────────────────────────────────────────────────
  static List<Map<String, dynamic>> _hazardList(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is List) {
          return d
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      } catch (_) {}
    }
    return const [];
  }
}
