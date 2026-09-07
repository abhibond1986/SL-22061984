/// Cleans up a hazard list before anyone reads it: merges findings that are the
/// same observation wearing three names, and refuses to let an unproven claim
/// that something is MISSING drive the severity of a report.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// A real scan of a steel-plant walkway came back with three CRITICAL/HIGH rows
/// — "Unprotected Fall Hazard", "Unsecured Walkway Edge", "Inadequate Fall
/// Protection" — which are one alleged finding, not three. The report therefore
/// announced "3 HAZARDS", and because the risk score escalates with hazard
/// count, a single disputed observation was inflated three times over.
///
/// Worse, the finding itself was wrong: the walkway in the photograph has a
/// handrail on both sides. The model had asserted an ABSENCE. That is the one
/// class of claim a vision model cannot support by pointing at pixels — you
/// cannot photograph a thing that is not there — and it is exactly the class the
/// existing anti-hallucination rules do not catch, because "there is no
/// guardrail" reads like an observation.
///
/// So this module does two things, and deliberately no more:
///   1. [dedupe]  — merge overlapping findings, keeping the worst severity.
///   2. [auditAbsenceClaims] — an unsupported absence claim is capped at LOW and
///      flagged for site verification. It is never deleted.
///
/// Nothing here removes a hazard. A false positive costs a safety officer a few
/// seconds of reading; a hazard deleted because software could not corroborate
/// it costs whatever the hazard goes on to cause. Merging is the one exception,
/// and it keeps every merged row's text.
///
/// Pure Dart, no Flutter import, so it runs under `dart run` in milliseconds —
/// see tools/hazard_quality_test.dart.
library;

/// What happened to one hazard, for logging and for the tests.
class QualityReport {
  const QualityReport({
    required this.merged,
    required this.absenceDowngraded,
    required this.absenceFlagged,
    this.boxesWithdrawn = 0,
    this.viewCapped = 0,
    this.sceneWithdrawn = 0,
    this.normalWithdrawn = 0,
    this.unverifiableMoved = 0,
  });

  /// Hazards folded into another row.
  final int merged;

  /// Absence claims whose severity was reduced.
  final int absenceDowngraded;

  /// Absence claims flagged, whether or not the severity moved.
  final int absenceFlagged;

  /// Bounding boxes too large to locate anything, so not drawn. The hazards
  /// themselves are untouched.
  final int boxesWithdrawn;

  /// Severities capped because the photograph is a general view that cannot
  /// support them. The findings themselves are untouched.
  final int viewCapped;

  /// Findings withdrawn because the requirement they cite does not exist in the
  /// place photographed — PPE rows raised against people seated in a meeting
  /// room. See [HazardQuality.auditSceneRelevance].
  final int sceneWithdrawn;

  /// Findings withdrawn because they described a designed feature in its normal
  /// state, or a normal operating condition, with no deviation named — a crane
  /// cabin bolted to its bridge, a load hanging from a hook with nobody under it.
  /// See [HazardQuality.auditNormalByDesign].
  final int normalWithdrawn;

  /// Findings moved out of the hazard table into `verifyOnSite` because the
  /// finding's own words said this photograph could not confirm it. Not deleted —
  /// they print as inspection points. See [HazardQuality.auditUnverifiable].
  final int unverifiableMoved;

  bool get changedAnything =>
      merged > 0 ||
      absenceDowngraded > 0 ||
      absenceFlagged > 0 ||
      boxesWithdrawn > 0 ||
      viewCapped > 0 ||
      sceneWithdrawn > 0 ||
      normalWithdrawn > 0 ||
      unverifiableMoved > 0;

  @override
  String toString() => 'QualityReport(merged: $merged, '
      'absenceDowngraded: $absenceDowngraded, '
      'absenceFlagged: $absenceFlagged, '
      'boxesWithdrawn: $boxesWithdrawn, '
      'viewCapped: $viewCapped, '
      'sceneWithdrawn: $sceneWithdrawn, '
      'normalWithdrawn: $normalWithdrawn, '
      'unverifiableMoved: $unverifiableMoved)';
}

class HazardQuality {
  HazardQuality._();

  /// Written onto the result so the pass is idempotent — the pipeline has eight
  /// exits and a cached report can flow through more than one of them.
  static const String kFlag = '_qualityChecked';

  /// Severity a hazard is capped at when its central claim is that something is
  /// missing and nothing in the finding establishes that.
  static const String kUnprovenSeverity = 'LOW';

  /// Ranking used for "keep the worst". Not read from admin master data on
  /// purpose: this module must stay pure Dart and synchronous, and the ordering
  /// of these four words has never been the configurable part — only their
  /// numeric scores are.
  static const List<String> severityOrder = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];

  /// Runs both passes over `result['hazards']` in place.
  ///
  /// Never throws: a tidy-up step must not be able to lose a scan the worker is
  /// standing in front of right now.
  static QualityReport apply(Map<String, dynamic> result, {bool force = false}) {
    try {
      if (result[kFlag] == true && !force) {
        return const QualityReport(
            merged: 0, absenceDowngraded: 0, absenceFlagged: 0);
      }
      final raw = result['hazards'];
      if (raw is! List || raw.isEmpty) {
        result[kFlag] = true;
        return const QualityReport(
            merged: 0, absenceDowngraded: 0, absenceFlagged: 0);
      }

      final hazards = <Map<String, dynamic>>[
        for (final h in raw)
          if (h is Map) h.cast<String, dynamic>(),
      ];

      // How many people the model could actually SEE in the photograph, copied
      // down onto every hazard so the renderers do not each have to be handed
      // the whole result map. Zero means no hazard in this image may draw an
      // arrow at a person: there is nobody there to draw it at.
      final seen = _peopleVisible(result);
      if (seen != null) {
        for (final h in hazards) {
          h['_peopleVisible'] = seen;
        }
      }

      final deduped = dedupe(hazards);
      final mergedCount = hazards.length - deduped.length;

      // Before anything is judged, decide whether the requirement each finding
      // cites applies to the place in the photograph at all. Runs after dedupe
      // (so a withdrawn row has already absorbed its duplicates and the audit
      // trail travels with it) and before the audits below (so the counts they
      // report describe rows that will actually be shown).
      final sceneWithdrawn = auditSceneRelevance(result, deduped);

      // Then: does the finding name a DEVIATION at all, or just a designed
      // feature doing its job? Runs immediately after the scene rule because the
      // two are the same kind of judgement — "the requirement does not exist
      // here" and "there is nothing wrong here" — and both must settle before the
      // audits below count rows that will be shown.
      // ★ MOVED BEFORE auditNormalByDesign, 2026-09-07. Nothing downstream reads
      // `absenceUnconfirmed` to change a withdrawal decision (an attempt to do
      // that was reverted — see [_deviationCues]), so this order is not required
      // for correctness. It is kept because the flag- and downgrade-counting loop
      // further down reads the marks this audit leaves on each row, and because
      // "was this claim proven?" is a question about the row itself, which is
      // cheaper to settle before any audit starts moving rows between lists.
      for (final h in deduped) {
        auditAbsenceClaim(h);
      }

      final normalWithdrawn = auditNormalByDesign(result, deduped);

      // Then remove the rows the model disclaimed itself. After the two
      // withdrawal audits, so a row that is BOTH normal-by-design and
      // unverifiable is withdrawn as the falsehood it is rather than filed as
      // something worth checking.
      final unverifiableMoved = auditUnverifiable(result, deduped);

      var downgraded = 0;
      var flagged = 0;
      var boxesWithdrawn = 0;
      for (final h in deduped) {
        // Box precision runs AFTER dedupe on purpose: the boxes are what dedupe
        // uses to decide that two rows describe the same object, so withdrawing
        // them first would lose merges.
        if (auditBoxPrecision(h)) boxesWithdrawn++;
        // Counted from the flags the absence audit left on the row, not by
        // calling it again: it MUTATES severity, so a second call would report a
        // second downgrade that never happened. Counting here rather than in the
        // loop above also keeps the promise the old code made — these numbers
        // describe rows that will actually be shown, and rows withdrawn in
        // between are correctly no longer counted.
        if (h.containsKey('absenceIssue') || h.containsKey('unmeasuredFigure')) {
          flagged++;
        }
        if (h.containsKey('severityBeforeAudit')) downgraded++;
      }

      // Last, because it reads the withdrawn boxes above as its evidence that the
      // photograph is a general view, and because capping first would make the
      // absence audit's "downgraded" count meaningless.
      final viewCapped = capSeverityForView(result, deduped);

      result['hazards'] = deduped;
      result[kFlag] = true;
      return QualityReport(
        merged: mergedCount,
        absenceDowngraded: downgraded,
        absenceFlagged: flagged,
        boxesWithdrawn: boxesWithdrawn,
        viewCapped: viewCapped,
        sceneWithdrawn: sceneWithdrawn,
        normalWithdrawn: normalWithdrawn,
        unverifiableMoved: unverifiableMoved,
      );
    } catch (_) {
      return const QualityReport(
          merged: 0, absenceDowngraded: 0, absenceFlagged: 0);
    }
  }

  /// The scan-level count of people visible in the photograph, or null when the
  /// model did not say. Null is NOT zero — an older report that never had the
  /// field must not be treated as an empty scene.
  static int? _peopleVisible(Map<String, dynamic> result) {
    // 'people' is the field the vision prompt has always asked for — "count of
    // ACTUALLY visible persons, 0 if none". The crane report answered 0 and then
    // described three workers, so this number was already there to be believed.
    for (final key in const [
      'peopleVisible',
      'personsVisible',
      'peopleInFrame',
      'visiblePeople',
      'people',
    ]) {
      final v = result[key];
      if (v is num) return v.toInt();
      if (v is bool) return v ? 1 : 0;
      if (v is String) {
        final n = int.tryParse(v.trim());
        if (n != null) return n;
        final s = v.trim().toLowerCase();
        if (s == 'none' || s == 'no' || s == 'nobody') return 0;
      }
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  DE-DUPLICATION
  // ═══════════════════════════════════════════════════════════════════════

  /// Hazard families. Two findings can only merge if they land in the SAME
  /// family, which stops "no helmet" being folded into "unguarded gear train"
  /// just because both mention a worker.
  ///
  /// Order matters: the first family whose keywords match wins, so the more
  /// specific families are listed before the broad ones.
  static const Map<String, List<String>> _families = {
    'fall-edge': [
      'guardrail', 'guard rail', 'handrail', 'hand rail', 'railing', 'toe board',
      'toeboard', 'open edge', 'unprotected edge', 'edge protection',
      'fall from height', 'fall hazard', 'fall protection', 'fall arrest',
      'harness', 'lanyard', 'working at height', 'work at height', 'parapet',
      'floor opening', 'walkway edge', 'platform edge', 'mezzanine',
    ],
    'ladder-access': [
      'ladder', 'staircase', 'stairway', 'stair tread', 'access route',
      'cage ladder', 'scaffold',
    ],
    'machine-guard': [
      'machine guard', 'guarding', 'unguarded', 'nip point', 'pinch point',
      'rotating', 'conveyor', 'gear', 'pulley', 'belt drive', 'coupling',
      'shaft', 'flywheel', 'interlock',
    ],
    'electrical': [
      'electrical', 'live wire', 'exposed conductor', 'earthing', 'earth',
      'switchgear', 'panel', 'cable', 'junction box', 'lockout', 'loto',
      'shock', 'insulation',
    ],
    'lifting': [
      'crane', 'suspended load', 'sling', 'hoist', 'lifting tackle', 'chain block',
      'rigging', 'load path', 'shackle', 'wire rope',
    ],
    'hot-molten': [
      'molten', 'slag', 'ladle', 'hot metal', 'tundish', 'furnace', 'tapping',
      'splash', 'radiant heat',
    ],
    'hot-work-fire': [
      'welding', 'gas cutting', 'hot work', 'fire', 'flammable', 'spark',
      'extinguisher', 'combustible',
    ],
    'gas-confined': [
      'gas leak', 'co gas', 'carbon monoxide', 'oxygen deficien', 'confined space',
      'manhole', 'cylinder', 'lpg', 'acetylene', 'purge',
    ],
    'ppe-head-eye': [
      'helmet', 'hard hat', 'goggle', 'face shield', 'safety glass',
      'eye protection', 'head protection',
    ],
    'ppe-other': [
      'ppe', 'safety shoe', 'glove', 'ear plug', 'ear muff', 'respirator',
      'mask', 'apron', 'personal protective',
    ],
    'housekeeping': [
      'housekeeping', 'spill', 'oil on floor', 'slippery', 'slip', 'trip',
      'clutter', 'debris', 'scrap', 'obstruct', 'stacking', 'storage',
    ],
    'vehicle': [
      'forklift', 'vehicle', 'tipper', 'dumper', 'traffic', 'reversing',
      'mobile equipment', 'locomotive', 'wagon', 'rail track',
    ],
  };

  /// Merges hazards that describe the same condition.
  ///
  /// The rules are deliberately cautious, because merging is the only
  /// destructive thing in this file:
  ///   • same family, AND
  ///   • if BOTH carry a usable bbox, the boxes must overlap (IoU ≥ [_minIou]) —
  ///     two unguarded machines at opposite ends of a photograph are two
  ///     findings, not one, and their boxes prove it;
  ///   • if either bbox is missing, the wording must overlap substantially
  ///     instead.
  static const double _minIou = 0.30;
  static const double _minTextOverlap = 0.34;

  static List<Map<String, dynamic>> dedupe(List<Map<String, dynamic>> hazards) {
    final kept = <Map<String, dynamic>>[];

    for (final h in hazards) {
      final family = familyOf(h);
      Map<String, dynamic>? target;

      if (family != null) {
        for (final k in kept) {
          if (familyOf(k) != family) continue;
          if (_isDuplicate(k, h)) {
            target = k;
            break;
          }
        }
      }

      if (target == null) {
        kept.add(h);
      } else {
        _mergeInto(target, h);
      }
    }
    return kept;
  }

  /// Which family a hazard belongs to, or null when nothing matches — an
  /// unclassifiable hazard is never merged, which is the safe default.
  static String? familyOf(Map hazard) {
    final text = _norm('${_str(hazard['name'])} ${_str(hazard['description'])} '
        '${_str(hazard['visualEvidence'])}');
    if (text.isEmpty) return null;
    for (final entry in _familyPatterns.entries) {
      for (final pattern in entry.value) {
        if (pattern.hasMatch(text)) return entry.key;
      }
    }
    return null;
  }

  /// Family keywords compiled to whole-word patterns.
  ///
  /// A plain `contains` looked fine and was wrong: "sli**ppe**ry" contains
  /// "ppe", so an oil spill was classified as a PPE finding and stopped merging
  /// with the identical spill reported next to it. Anchoring on word boundaries
  /// (with a tolerant plural/gerund tail so "rail" still catches "railing") is
  /// what makes the family gate mean anything.
  static final Map<String, List<RegExp>> _familyPatterns = {
    for (final entry in _families.entries)
      entry.key: [
        for (final kw in entry.value)
          RegExp('\\b${RegExp.escape(kw)}(?:s|es|ing)?\\b'),
      ],
  };

  static bool _isDuplicate(Map<String, dynamic> a, Map<String, dynamic> b) {
    final boxA = _bbox(a['bbox']);
    final boxB = _bbox(b['bbox']);
    if (boxA != null && boxB != null) {
      return _iou(boxA, boxB) >= _minIou;
    }
    return _textOverlap(a, b) >= _minTextOverlap;
  }

  /// Folds [extra] into [keep]: worst severity wins, the fuller description
  /// wins, and corrective actions accumulate so no remedy is lost.
  static void _mergeInto(Map<String, dynamic> keep, Map<String, dynamic> extra) {
    if (severityRank(_str(extra['severity'])) >
        severityRank(_str(keep['severity']))) {
      keep['severity'] = _str(extra['severity']);
    }

    // The longer description is usually the one with the specifics; the shorter
    // one is kept as a note rather than thrown away, because it may name a
    // detail the other missed.
    final dKeep = _str(keep['description']);
    final dExtra = _str(extra['description']);
    if (dExtra.length > dKeep.length) {
      keep['description'] = dExtra;
    }

    keep['correctiveAction'] =
        _joinDistinct(_str(keep['correctiveAction']), _str(extra['correctiveAction']));

    // A merged row must not look MORE certain than its parts.
    final cKeep = _asInt(keep['confidence']);
    final cExtra = _asInt(extra['confidence']);
    if (cKeep != null && cExtra != null && cExtra < cKeep) {
      keep['confidence'] = cExtra;
    }

    // Fill in anything the kept row lacks.
    for (final key in const [
      'bbox', 'lofZone', 'regulation', 'visualEvidence', 'absenceCheck',
      'type', 'wsaCause',
    ]) {
      final have = keep[key];
      final missing = have == null || (have is String && have.trim().isEmpty);
      if (missing && extra[key] != null) keep[key] = extra[key];
    }

    // Audit trail: the merged names stay visible so a reviewer can see that the
    // model said this three ways and the app said it once.
    final names = <String>[
      ...(keep['mergedFrom'] is List
          ? (keep['mergedFrom'] as List).map(_str)
          : const <String>[]),
    ];
    if (names.isEmpty) {
      final own = _str(keep['name']);
      if (own.isNotEmpty) names.add(own);
    }
    final extraName = _str(extra['name']);
    if (extraName.isNotEmpty && !names.contains(extraName)) names.add(extraName);
    keep['mergedFrom'] = names;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  BOX PRECISION
  // ═══════════════════════════════════════════════════════════════════════

  /// Fraction of the frame a bounding box may cover and still be a locator.
  ///
  /// A box over this is not pointing at anything — it is pointing at the
  /// photograph. Set from the report that prompted the rule: a stockyard panorama
  /// whose "Unguarded Elevated Walkway" box spanned about 90% of the frame width
  /// and a third of its height, i.e. roughly a third of the whole image.
  static const double _maxBoxArea = 0.30;

  /// A box may also fail on a single dimension: 95% of the width at 20% height is
  /// only 0.19 of the area, but it is still a stripe across the entire picture and
  /// tells a reader nothing about WHERE to look.
  static const double _maxBoxSpan = 0.88;

  /// Demotes a bounding box that is too large to locate anything.
  ///
  /// **Why:** a box is a promise — "the thing I am describing is HERE". A box
  /// covering most of the frame breaks that promise while looking authoritative,
  /// and it does specific damage: the reader cannot tell which structure was meant,
  /// and on a printed report the numbered tag sits over unrelated plant. The
  /// stockyard scan drew one across an entire panorama and labelled it CRITICAL.
  ///
  /// **How to apply:** the HAZARD IS KEPT, with its severity and its table row
  /// untouched — nothing here decides whether a finding is real. Only the drawing
  /// is withdrawn: the box moves to `bboxRejected` (kept, not deleted, so it can be
  /// inspected) and `locationUnpinned` / `locationIssue` say why, in the same shape
  /// the absence audit uses so the screen renders it the same way. Returns true if
  /// a box was withdrawn.
  static bool auditBoxPrecision(Map<String, dynamic> hazard) {
    final box = _bbox(hazard['bbox']);
    if (box == null) return false;
    final area = box.w * box.h;
    final spans = box.w >= _maxBoxSpan || box.h >= _maxBoxSpan;
    if (area <= _maxBoxArea && !spans) return false;

    hazard['bboxRejected'] = hazard['bbox'];
    hazard.remove('bbox');
    hazard['locationUnpinned'] = true;
    hazard['locationIssue'] =
        'The marked area covered ${(area * 100).round()}% of the photograph, so '
        'it could not show which structure this refers to. The box was not drawn '
        '— identify the exact location on site.';
    return true;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  WHAT THE PHOTOGRAPH CAN SUPPORT
  // ═══════════════════════════════════════════════════════════════════════

  /// Highest severity a photograph that cannot be inspected may carry.
  static const String kUninspectableSeverity = 'MEDIUM';

  /// A box small enough that the model was looking AT something rather than at
  /// the site. One such box anywhere in the frame is enough to treat the
  /// photograph as inspectable.
  static const double _closeBoxArea = 0.10;

  /// Written onto the result when the photograph is a general view.
  static const String kUninspectableFlag = '_viewUninspectable';

  /// Sentence added to the report when that happens. Deliberately about the
  /// PHOTOGRAPH, not the site: nothing here says the site is safe.
  static const String kUninspectableCaveat =
      'General view — observations pending site verification. This photograph '
      'shows the area from a distance, so nothing in it can be confirmed close '
      'enough to raise or close out a non-conformance. Re-photograph each item '
      'at working distance before acting on a severity.';

  /// Whether this photograph is too wide or too distant to inspect anything in.
  ///
  /// **Why:** a hazy panorama of a stockyard and agglomeration area, shot from
  /// perhaps a hundred metres, produced three findings and a CRITICAL banner at
  /// 23/100. A 30-year safety professional would not write a CRITICAL
  /// non-conformance from that frame — not because the site looks fine, but
  /// because the photograph cannot establish access, guarding at a nip point, or
  /// whether anyone was working there. The finding is worth recording; the
  /// severity is not earned.
  ///
  /// **How to apply:** the model's own answer is believed first if it gave one
  /// (`viewType` / `inspectable`). Otherwise the boxes are the evidence: if the
  /// pass had to withdraw a box for covering the frame ([auditBoxPrecision]) and
  /// no remaining box is tight enough to be looking at a single object, then
  /// nothing in this image was localised and it is a general view.
  static bool viewIsUninspectable(
      Map<String, dynamic> result, List<Map<String, dynamic>> hazards) {
    final declared = _str(result['viewType']).toUpperCase();
    if (declared.contains('GENERAL') ||
        declared.contains('DISTANT') ||
        declared.contains('PANORAM')) {
      return true;
    }
    if (declared.contains('CLOSE') || declared.contains('WORKING')) return false;
    final inspectable = result['inspectable'];
    if (inspectable is bool) return !inspectable;

    if (hazards.isEmpty) return false;
    final withdrew = hazards.any((h) => h['locationUnpinned'] == true);
    if (!withdrew) return false;
    final pinned = hazards.any((h) {
      final b = _bbox(h['bbox']);
      return b != null && b.w * b.h <= _closeBoxArea;
    });
    return !pinned;
  }

  /// Caps every severity on an uninspectable photograph and labels the report.
  ///
  /// The hazards, their text and their corrective actions are untouched — only the
  /// claim about how bad it is, which is the one claim the photograph cannot
  /// support. Each capped row keeps `severityBeforeViewCap` so the model's own
  /// judgement is still on the record. Returns how many rows were capped.
  static int capSeverityForView(
      Map<String, dynamic> result, List<Map<String, dynamic>> hazards) {
    if (!viewIsUninspectable(result, hazards)) return 0;
    result[kUninspectableFlag] = true;
    result['viewCaveat'] = kUninspectableCaveat;
    var capped = 0;
    for (final h in hazards) {
      final before = _str(h['severity']);
      if (severityRank(before) <= severityRank(kUninspectableSeverity)) continue;
      h['severityBeforeViewCap'] = before;
      h['severity'] = kUninspectableSeverity;
      capped++;
    }
    // The banner is derived from the rows on the screen but stored separately in
    // the record, so it has to be brought down too or the report contradicts
    // itself again — a MEDIUM row list under a CRITICAL headline.
    final overall = _str(result['overallRisk']);
    if (overall.isNotEmpty &&
        severityRank(overall) > severityRank(kUninspectableSeverity)) {
      result['overallRiskBeforeViewCap'] = overall;
      result['overallRisk'] = kUninspectableSeverity;
    }
    return capped;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  DOES THE RULE APPLY HERE AT ALL?
  // ═══════════════════════════════════════════════════════════════════════

  /// Written onto the result when the photograph is not of a workplace where
  /// industrial PPE is required.
  static const String kNonIndustrialFlag = '_sceneNonIndustrial';

  /// Where withdrawn findings go. They are NOT deleted — see the note on
  /// [auditSceneRelevance] about why this is the one place in this file that
  /// takes a row off the list.
  static const String kWithdrawnKey = 'withdrawnHazards';

  /// Cues that the frame is a meeting room, office, classroom or canteen.
  ///
  /// Matched against `sceneInventory` and `summary` — the model's own plain
  /// description of what it can see, written before it was allowed to judge
  /// anything, which makes it the most trustworthy sentence in the response.
  static final List<RegExp> _nonIndustrialCues = [
    for (final kw in const [
      'conference hall', 'conference room', 'conference table', 'meeting room',
      'meeting hall', 'boardroom', 'board room', 'seminar hall', 'seminar room',
      'auditorium', 'lecture hall', 'lecture theatre', 'classroom',
      'class room', 'training room', 'training hall', 'committee room',
      'office room', 'office cabin', 'office desk', 'cubicle', 'workstation',
      'reception', 'canteen', 'dining hall', 'dining room', 'cafeteria',
      'pantry', 'guest house', 'hotel', 'banquet',
      'projector', 'projection screen', 'presentation screen', 'whiteboard',
      'white board', 'podium', 'lectern', 'dais', 'stage backdrop',
      'notice board', 'laptop', 'laptops', 'desktop computer', 'keyboard',
      'microphone', 'water bottles', 'notepad', 'notepads', 'stationery',
      'upholstered chairs', 'office chairs', 'swivel chairs', 'carpeted floor',
      'carpet', 'false ceiling', 'air conditioner', 'curtains',
      'seated around a table', 'seated at a table', 'seated audience',
      'attendees', 'delegates', 'participants seated',
    ])
      RegExp('\\b${RegExp.escape(kw)}(?:s|es)?\\b', caseSensitive: false),
  ];

  /// Cues that there IS industrial plant in the frame, which veto the above.
  ///
  /// A control room with a window onto the converter, a training hall with a
  /// cutting demonstration set up in it, or a "meeting" held on a shop floor are
  /// all real, and in every one of them the PPE finding may be correct. The rule
  /// only fires when the frame contains a non-industrial setting and NOTHING
  /// industrial, which is the only case where the requirement demonstrably does
  /// not exist.
  static final List<RegExp> _industrialCues = [
    for (final kw in const [
      'furnace', 'ladle', 'molten', 'slag', 'tundish', 'blast', 'coke oven',
      'converter', 'caster', 'rolling mill', 'mill', 'shop floor', 'workshop',
      'bay', 'crane', 'hoist', 'conveyor', 'rotating', 'machinery', 'machine',
      'lathe', 'grinder', 'welding', 'gas cutting', 'torch', 'scaffold',
      'excavator', 'forklift', 'tipper', 'dumper', 'locomotive', 'wagon',
      'rail track', 'pipeline', 'pipe rack', 'valve', 'boiler', 'turbine',
      'switchgear', 'transformer', 'busbar', 'gantry', 'girder', 'rebar',
      'shuttering', 'trench', 'excavation', 'stockyard', 'scrap yard',
      'construction', 'site work', 'hard hat', 'helmet', 'coverall',
      'high visibility', 'hi vis', 'safety shoe', 'boiler suit',
    ])
      RegExp('\\b${RegExp.escape(kw)}(?:s|es|ing)?\\b', caseSensitive: false),
  ];

  /// Hazard families whose requirement simply does not exist in a meeting room.
  ///
  /// Deliberately ONLY the two PPE families. Housekeeping is not here: a cable
  /// trailing across a conference-room floor is a genuine trip hazard and the
  /// report should say so. Nor are the machine, electrical or lifting families —
  /// if one of those matched, an industrial cue almost certainly matched too and
  /// the rule will not have fired at all.
  static const Set<String> _familiesNotRequiredIndoors = {
    'ppe-head-eye',
    'ppe-other',
  };

  /// Whether the photograph shows a place where industrial PPE is not required.
  ///
  /// The model's own `sceneType` is believed first when it gave one; otherwise
  /// this reads the cues above. Returns false whenever it is not sure, because
  /// the cost of guessing wrong in this direction is a suppressed real hazard.
  static bool sceneIsNonIndustrial(Map<String, dynamic> result) {
    final declared = _str(result['sceneType']).toUpperCase();
    if (declared.isNotEmpty) {
      if (declared.contains('INDUSTRIAL') && !declared.contains('NON')) {
        return false;
      }
      if (declared.contains('OFFICE') ||
          declared.contains('MEETING') ||
          declared.contains('NON_INDUSTRIAL') ||
          declared.contains('NON-INDUSTRIAL')) {
        // Still require no industrial cue: the model has, in the past, labelled
        // a frame OFFICE and then described a gas cylinder standing in it.
        return !_anyMatch(_industrialCues, _inventoryText(result));
      }
      // OUTDOOR_PUBLIC / UNCLEAR and anything unrecognised fall through to the
      // cue test rather than being trusted either way.
    }
    if (_anyMatch(_industrialCues, _inventoryText(result))) return false;
    final text = _sceneText(result);
    if (text.trim().length < 20) return false; // nothing to reason from
    return _anyMatch(_nonIndustrialCues, text);
  }

  /// Where the INDUSTRIAL veto looks: the inventory only, falling back to the
  /// summary when the model gave no inventory.
  ///
  /// The summary is excluded whenever there is an inventory because the prompt
  /// asks for the primary safety concern in it, so a summary reading "the seated
  /// attendees are not wearing helmets" would supply the very industrial cue
  /// ("helmet") that vetoes withdrawing that finding — the rule would disarm
  /// itself on precisely the reports it exists for. The inventory is written
  /// before the model is allowed to judge anything and names only what is
  /// physically in the frame, so a helmet appearing there really does mean a
  /// helmet is in the picture.
  static String _inventoryText(Map<String, dynamic> result) {
    final inv = _str(result['sceneInventory']);
    return inv.isNotEmpty ? inv : _str(result['summary']);
  }

  /// Where the non-industrial cues look. The summary is included here because a
  /// stray office word in it can only ever make the rule fire, and the rule then
  /// still has to clear the veto above.
  static String _sceneText(Map<String, dynamic> result) =>
      '${_str(result['sceneInventory'])} ${_str(result['summary'])}';

  static bool _anyMatch(List<RegExp> patterns, String text) {
    for (final p in patterns) {
      if (p.hasMatch(text)) return true;
    }
    return false;
  }

  /// Removes findings whose requirement does not exist in the place photographed,
  /// and returns how many were removed.
  ///
  /// **Why:** a scan of people sitting at a conference table came back with
  /// "Missing PPE" at MEDIUM, citing Factories Act 1948 s.41C, in the same report
  /// whose own summary said "no immediate physical hazards are clearly visible in
  /// the frame". Nobody needs a helmet to attend a meeting. This is not a hazard
  /// that might be true and cannot be confirmed — the category of requirement
  /// does not apply — and the damage is specific: a safety officer who is handed
  /// a non-conformance for not wearing a hard hat indoors learns to skim the
  /// table, and the next report's real finding is skimmed with it.
  ///
  /// **How to apply:** this is the ONE exception to "nothing here removes a
  /// hazard", and it is narrowed until it can only catch that mistake — the
  /// frame must carry a non-industrial cue, carry NO industrial cue, and the
  /// finding must be in a PPE family. Even then the row is not destroyed: it
  /// moves to `result['withdrawnHazards']` with `withdrawnReason`, so it remains
  /// in the saved record and can be shown behind a disclosure. The report also
  /// gets [kNonIndustrialFlag] and a `sceneNote`, so a reader can see that the
  /// app made a judgement rather than that the model found nothing.
  static int auditSceneRelevance(
      Map<String, dynamic> result, List<Map<String, dynamic>> hazards) {
    if (!sceneIsNonIndustrial(result)) return 0;
    result[kNonIndustrialFlag] = true;

    final withdrawn = <Map<String, dynamic>>[];
    hazards.removeWhere((h) {
      final family = familyOf(h);
      if (family == null || !_familiesNotRequiredIndoors.contains(family)) {
        return false;
      }
      h['withdrawnReason'] =
          'Withdrawn by the app: this photograph shows an office or meeting '
          'setting with no plant or equipment in it, so industrial PPE is not '
          'required here. The finding was not shown as a non-conformance.';
      withdrawn.add(h);
      return true;
    });

    if (withdrawn.isEmpty) return 0;

    final existing = result[kWithdrawnKey];
    result[kWithdrawnKey] = <Map<String, dynamic>>[
      if (existing is List)
        for (final e in existing)
          if (e is Map) e.cast<String, dynamic>(),
      ...withdrawn,
    ];
    result['sceneNote'] =
        '${withdrawn.length} PPE observation${withdrawn.length == 1 ? '' : 's'} '
        'withdrawn — the frame is an office or meeting area, not a work area '
        'where PPE is required.';

    // The banner and the score are derived from the rows, so they have to follow
    // them down or the report contradicts itself: a MEDIUM headline over an
    // empty table is exactly the output that prompted this rule.
    if (hazards.isEmpty) {
      final overall = _str(result['overallRisk']);
      if (overall.isNotEmpty && severityRank(overall) > severityRank('LOW')) {
        result['overallRiskBeforeSceneAudit'] = overall;
        result['overallRisk'] = 'LOW';
      }
      final score = _asInt(result['riskScore']);
      if (score != null && score > 15) {
        result['riskScoreBeforeSceneAudit'] = score;
        result['riskScore'] = 15;
      }
    }
    return withdrawn.length;
  }

  // ── NORMAL BY DESIGN ─────────────────────────────────────────────────────
  //
  // The second and last place in this file that takes a row off the list, and it
  // exists for the same reason as [auditSceneRelevance]: the finding is not a
  // hazard that might be true and cannot be confirmed, it is a description of a
  // thing being what it was built to be.
  //
  // **Why, in the reporter's own words (2026-09-07).** A crane scan came back
  // with "Operator cabin suspended ..." and "Crane bridge walkway acc..." — both
  // LOW, both meaningless. The safety officer who raised it: *"crane cabin is
  // always fixed with the structure, its the design element. i dont know why it
  // is shown as a hazard. also the load will obviously be suspended .. i cant
  // understand why is it a hazard unless some person is directly below it."*
  //
  // That is the whole rule. An EOT crane's cabin is bolted to the girder; a load
  // hangs from the hook. Reporting either as a non-conformance produces a report
  // with nothing to action, and — exactly as with helmets in a conference hall —
  // trains the reader to skim the table that also holds the real finding.

  /// Written onto the result when at least one normal-state finding was withdrawn.
  static const String kNormalByDesignFlag = '_normalByDesignWithdrawn';

  /// Things that are SUPPOSED to be there, keyed by the phrase that gives them
  /// away. Matched against the hazard's own name + description + visual evidence.
  ///
  /// Each entry is a designed feature or a normal operating state. None of them
  /// is inherently wrong, and none of them can be made wrong by its mere
  /// presence — only by a defect, which [_deviationCues] below detects and which
  /// vetoes this whole rule for that row.
  static final List<RegExp> _normalStateCues = [
    for (final kw in const [
      // Crane structure. The cabin, and the walkway that serves it, are welded
      // or bolted to the bridge girder — that is the design.
      'operator cabin', 'operators cabin', 'crane cabin', 'driver cabin',
      'cabin suspended', 'suspended cabin', 'cabin mounted', 'cabin attached',
      'cabin fixed', 'cabin at height', 'cabin located', 'cabin positioned',
      'elevated cabin', 'cabin access', 'crane bridge', 'bridge girder',
      'crane girder', 'crane walkway', 'bridge walkway', 'walkway access',
      'access walkway', 'maintenance walkway', 'catwalk', 'gantry walkway',
      'trolley mounted', 'end carriage', 'long travel', 'cross travel',
      'festoon', 'downshop lead',
      // Normal lifting. A load in the air is a lift, not a hazard.
      'suspended load', 'load suspended', 'hanging load', 'load hanging',
      'load hoisted', 'hoisted load', 'load lifted', 'lifted load',
      'load on hook', 'load on the hook', 'material suspended',
      'suspended material', 'suspended from the hook', 'suspended from hook',
      'lifting magnet', 'magnet suspended', 'grab suspended', 'ladle suspended',
      'load at height', 'elevated load', 'load overhead', 'overhead load',
      // The hook itself, loaded or empty. ★ ADDED 2026-09-07 after a live scan
      // filed "Hanging crane hook block ..." at LOW on a build that ALREADY had
      // this rule: every cue above names the LOAD, and an idle hook block carries
      // none. A hook block hangs from the rope whether or not anything is on it —
      // parking it at height is where it is supposed to be, not a finding. Note
      // 'block' is safe to use here: the veto lists 'blocked', whose suffix
      // pattern cannot match the bare noun.
      'hook block', 'hook blocks', 'crane hook', 'lifting hook', 'hoist hook',
      'hoist block', 'load block', 'bottom block', 'sheave block',
      'hanging hook', 'hook hanging', 'hook suspended', 'suspended hook',
      'hook at height', 'hook lowered', 'hook raised', 'empty hook',
      'unloaded hook', 'bare hook', 'idle hook', 'hook assembly',
      'hook and block', 'wire rope hoist', 'rope drum',
      // The lifting ATTACHMENT on the end of the rope. ★ ADDED 2026-09-07 after a
      // scan of a blast-furnace ore bridge called the grab bucket hanging from
      // the trolley "a suspended operator/maintenance cabin" and asked for a
      // secondary retention rope on it. Two separate errors in one row: a bucket
      // was mistaken for a manned cabin, and a requirement that does not exist
      // was invented for it — a hoisted attachment hangs on the hoist rope, that
      // is the design, and nothing gets a backup lanyard.
      //
      // Note that the cabin cues above DID match that row — the withdrawal was
      // vetoed by the model's own guessed word "without". Weakening the veto for
      // guessed absences was tried and reverted ([_deviationCues]); what actually
      // removes that row from the hazard table is [auditUnverifiable], because it
      // admitted it could not resolve what it was looking at. These cues are still
      // worth having: they stop the NEXT such row from being filed at all when it
      // is written without a hedge.
      'grab bucket', 'grab buckets', 'clamshell', 'clam shell', 'bucket grab',
      'grab attachment', 'bucket suspended', 'suspended bucket',
      'hanging bucket', 'bucket hanging', 'bucket at height',
      'lifting beam', 'lifting frame', 'spreader beam', 'lifting tackle',
      'hoist attachment', 'lifting attachment', 'end effector',
      'tong', 'tongs', 'ladle hook', 'charging bucket', 'skip bucket',
      'magnet attachment', 'lifting magnet suspended', 'orange peel grab',
      // Being at height / near plant, offered as a hazard in itself.
      'working at height', 'work at height', 'at elevated height',
      'height of the structure', 'structure at height', 'elevated structure',
      'elevated position', 'overhead structure', 'overhead crane present',
      'presence of crane', 'presence of overhead', 'proximity to plant',
    ])
      RegExp('\\b${RegExp.escape(kw)}(?:s|es)?\\b', caseSensitive: false),
  ];

  /// The VETO. Any of these anywhere in the row's own text means a real defect or
  /// a real exposure was named, and the row survives untouched.
  ///
  /// Deliberately generous — every word here that fires wrongly costs one false
  /// hazard kept, while every word MISSING from this list costs a real defect
  /// silently withdrawn. Those are not comparable, so the list errs long.
  ///
  /// ★ A SPLIT WAS TRIED HERE ON 2026-09-07 AND DELIBERATELY REVERTED. Read this
  /// before attempting it again. A live scan filed "Suspended cabin without
  /// visible secondary retention": `suspended cabin` IS in [_normalStateCues], so
  /// the withdrawal fired correctly and was then vetoed by the word **without**,
  /// which the model supplied itself while admitting in the same breath that
  /// "from a distant, silhouetted view the arrangement cannot be fully resolved".
  /// A finding had immunised itself against suppression by guessing.
  ///
  /// The attempted fix moved the pure "not there" words (`missing`, `without`,
  /// `no guard`, `unguarded`…) into a weak group that stops vetoing once
  /// [auditAbsenceClaim] has ruled the claim unproven. Two things killed it:
  ///
  /// 1. **It did not fix the reported case.** `claimsAbsence` requires an absence
  ///    word AND a recognised protective thing, and "secondary retention" is not
  ///    in [_protectiveThing] — so `absenceUnconfirmed` was never set on that very
  ///    row and the weakening never engaged. A rule keyed on another rule's flag
  ///    inherits that rule's blind spots.
  /// 2. **It withdrew a real finding.** "Missing handrail on cabin access
  ///    walkway" carries no observed-defect word, mentions a normal-state cue
  ///    (`cabin`), and is routinely filed without an `absenceCheck` — so it became
  ///    unproven-and-vetoless and was DELETED, where the absence audit had
  ///    correctly been merely downgrading it to LOW.
  ///
  /// The reported row is handled properly by two other changes instead: the
  /// lifting-attachment cues (so a grab bucket is not called a cabin at all) and
  /// [auditUnverifiable], which moves any row that disclaims itself — as that one
  /// did — out of the hazard table without destroying it. **Withdrawal is the
  /// heaviest instrument in this file; when a row is doubtful rather than wrong,
  /// downgrade it or move it, do not widen what deletes it.**
  static final List<RegExp> _deviationCues = [
    for (final kw in _kDeviationWords)
      RegExp('\\b${RegExp.escape(kw)}(?:s|es|ed|ing)?\\b', caseSensitive: false),
  ];

  static const List<String> _kDeviationWords = [
      // Something is not there. These veto unconditionally — see the doc comment
      // above for why an attempt to make them conditional was reverted.
      'missing', 'absent', 'without', 'no guard', 'unguarded', 'unprotected',
      'no handrail', 'handrail missing', 'no railing', 'railing missing',
      'no toe board', 'no barricade', 'not barricaded', 'unbarricaded',
      'no cover', 'unfenced', 'no fall arrest', 'no lifeline', 'no safety net',
      'not anchored', 'unsecured', 'not secured', 'no permit', 'without permit',
      'not tagged', 'no lockout', 'no signage', 'no sign', 'no illumination',
      'uncertified', 'not rated',
      // Structural / mechanical defect.
      'crack', 'cracked', 'broken', 'break',
      'corroded', 'corrosion', 'rust', 'rusted', 'rusty', 'worn', 'wear',
      'damaged', 'damage', 'bent', 'buckled', 'deformed', 'distorted',
      'loose', 'slack', 'detached', 'dislodged', 'displaced', 'gap', 'hole',
      'frayed', 'fray', 'kinked', 'twisted', 'stretched', 'elongated',
      'defective', 'faulty', 'failed', 'failure', 'weakened', 'sagging',
      'leaking', 'leak', 'spill', 'spilled',
      // Guarding and protection, in the forms that assert an observation — a
      // guard you can see has been taken off, an edge you can see is open.
      'guard removed', 'toe guard', 'cover removed', 'open edge',
      // Exposure — a person in the wrong place. This is the whole point of the
      // suspended-load carve-out the reporter described.
      'person below', 'person beneath', 'person under', 'people below',
      'people beneath', 'people under', 'worker below', 'worker beneath',
      'worker under', 'workers below', 'workers beneath', 'workers under',
      'standing below', 'standing beneath', 'standing under', 'walking below',
      'walking beneath', 'walking under', 'working below', 'working beneath',
      'working under', 'passing below', 'passing beneath', 'passing under',
      'directly below', 'directly beneath', 'directly under', 'underneath',
      'line of fire', 'in the path', 'struck by', 'swing radius',
      'occupied', 'personnel in', 'man below',
      // Operating and procedural deviation.
      'overload', 'overloaded', 'exceeds', 'exceeding', 'unsafe', 'improper',
      'incorrect', 'wrong', 'expired',
      'unauthorised', 'unauthorized',
      'obstructed', 'blocked', 'obstruction', 'debris', 'housekeeping',
      'slippery', 'wet', 'poor illumination',
      'energised',
      'energized', 'exposed conductor', 'bare conductor', 'unattended',
  ];

  /// The row's own words — everything the model wrote about THIS finding.
  ///
  /// The scan-level summary is excluded on purpose. A summary sentence naming a
  /// real defect elsewhere in the frame would veto the withdrawal of an unrelated
  /// normal-state row, which is the self-disarming failure that
  /// [_inventoryText]'s doc comment describes for the PPE rule.
  static String _hazardText(Map hazard) => [
        _str(hazard['name']),
        _str(hazard['description']),
        _str(hazard['visualEvidence']),
        _str(hazard['correctiveAction']),
      ].join(' ');

  /// Whether this row describes only a normal state, with no deviation named.
  static bool describesNormalStateOnly(Map hazard) {
    final text = _hazardText(hazard);
    // Nothing to reason from. Calling an empty row "normal" would withdraw
    // findings for being badly written rather than for being wrong.
    if (text.trim().length < 12) return false;
    if (!_anyMatch(_normalStateCues, text)) return false;

    // One veto, applied unconditionally. This function must NOT consult
    // `absenceUnconfirmed` or any other row flag to decide how hard to look for a
    // deviation — see the [_deviationCues] doc comment for the reverted attempt
    // and the two ways it went wrong.
    return !_anyMatch(_deviationCues, text);
  }

  /// Withdraws normal-state findings and returns how many were removed.
  ///
  /// **How to apply:** three conditions, all required, mirroring the PPE rule's
  /// narrowness — the row must name a designed feature or normal operating state,
  /// must name NO deviation from [_deviationCues], and is moved to
  /// `withdrawnHazards` rather than destroyed, so the record still shows what the
  /// model said and why the app disagreed.
  ///
  /// Note this rule is scene-independent: unlike [auditSceneRelevance] it does
  /// NOT require a non-industrial frame. A crane cabin is a design element on the
  /// shop floor too — which is precisely where it was wrongly reported.
  static int auditNormalByDesign(
      Map<String, dynamic> result, List<Map<String, dynamic>> hazards) {
    final withdrawn = <Map<String, dynamic>>[];
    hazards.removeWhere((h) {
      if (!describesNormalStateOnly(h)) return false;
      h['withdrawnReason'] =
          'Withdrawn by the app: this describes equipment in its normal, '
          'as-designed state — for example a crane cabin fixed to the bridge, or '
          'a load hanging from the hook with nobody underneath it — and names no '
          'defect, deviation or exposed person. It was not shown as a '
          'non-conformance.';
      withdrawn.add(h);
      return true;
    });

    if (withdrawn.isEmpty) return 0;

    result[kNormalByDesignFlag] = true;
    final existing = result[kWithdrawnKey];
    result[kWithdrawnKey] = <Map<String, dynamic>>[
      if (existing is List)
        for (final e in existing)
          if (e is Map) e.cast<String, dynamic>(),
      ...withdrawn,
    ];

    // Appended, not assigned: auditSceneRelevance may already have written a
    // note, and overwriting it would hide one of the two judgements the app made.
    final note = '${withdrawn.length} observation'
        '${withdrawn.length == 1 ? '' : 's'} withdrawn — equipment in its normal '
        'designed state, with no defect or exposed person visible.';
    final prior = _str(result['sceneNote']);
    result['sceneNote'] = prior.isEmpty ? note : '$prior $note';

    // Same reason as in auditSceneRelevance: the banner and the score are derived
    // from the rows, so when the rows go the headline must follow or the report
    // contradicts itself.
    if (hazards.isEmpty) {
      final overall = _str(result['overallRisk']);
      if (overall.isNotEmpty && severityRank(overall) > severityRank('LOW')) {
        result['overallRiskBeforeSceneAudit'] = overall;
        result['overallRisk'] = 'LOW';
      }
      final score = _asInt(result['riskScore']);
      if (score != null && score > 15) {
        result['riskScoreBeforeSceneAudit'] = score;
        result['riskScore'] = 15;
      }
    }
    return withdrawn.length;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SELF-ADMITTED UNVERIFIABLE FINDINGS  ★ added 2026-09-07
  // ═══════════════════════════════════════════════════════════════════════

  /// Key holding findings moved out of the hazards table because the model itself
  /// said they could not be confirmed. These are inspection points, not
  /// non-conformances.
  static const String kVerifyOnSiteKey = 'verifyOnSite';

  /// Set when [auditUnverifiable] moved at least one row.
  static const String kVerifyOnSiteFlag = '_verifyOnSiteMoved';

  /// Phrases in which the model states, about its OWN finding, that the frame
  /// cannot settle it.
  ///
  /// **Why this class needed its own rule.** A scan of a distant, backlit ore
  /// bridge produced three rows, and every one of them argued against itself:
  /// *"specific defects cannot be confirmed from this distant frame"*,
  /// *"whether any section is perforated or structurally significant cannot be
  /// determined from this distance"*, *"floor-plate and handrail condition cannot
  /// be confirmed from this frame"*. The third was even NAMED
  /// "Stair/ladder tower platform integrity to be verified" — a task, not a
  /// finding. Neither existing audit could touch them: they make no absence
  /// claim, quote no invented measurement, and name real deviation words
  /// (corrosion, rust), so `auditNormalByDesign` correctly left them alone.
  ///
  /// The model had in effect written *"I could not see"* three times, and the app
  /// printed it as **3 HAZARDS IDENTIFIED** under a MEDIUM banner. That is the
  /// specific harm: a safety officer reading the count cannot tell a confirmed
  /// defect from an admission of poor visibility.
  ///
  /// Kept deliberately tight. Every phrase here is the model explicitly
  /// disclaiming its own row — not mere hedging, which [_hedged] already handles
  /// by capping severity. "Appears rusty" stays a hazard; "whether it is rusty
  /// cannot be determined" does not.
  static final List<RegExp> _selfDisclaimCues = [
    for (final kw in const [
      'cannot be confirmed', 'can not be confirmed', 'could not be confirmed',
      'cannot be determined', 'can not be determined',
      'could not be determined',
      'cannot be verified', 'can not be verified', 'cannot be established',
      'cannot be assessed', 'cannot be resolved', 'cannot be fully resolved',
      'cannot be ruled out', 'cannot be confirmed from', 'not confirmable',
      'unable to confirm', 'unable to determine', 'unable to verify',
      'unable to assess', 'impossible to confirm', 'impossible to determine',
      'to be verified', 'to be confirmed', 'requires verification',
      'requires confirmation', 'needs verification', 'pending verification',
      'subject to verification', 'warrants closer inspection',
      'warrants close inspection', 'requires closer inspection',
      'needs closer inspection', 'should be inspected closer',
      'observation to verify', 'verify at close range',
      'not resolvable', 'indeterminate from', 'inconclusive',
    ])
      RegExp(RegExp.escape(kw), caseSensitive: false),
  ];

  /// True when the row's own words disclaim it.
  ///
  /// Reads name + description + visualEvidence and **excludes
  /// `correctiveAction`**, which is the opposite choice to [_hazardText] and the
  /// one detail most likely to be "corrected" wrongly later. A corrective action
  /// is *supposed* to say "inspect at close range and confirm" — that is what a
  /// good corrective action for a real distant observation looks like. Including
  /// it would move almost every legitimate finding on a general view into the
  /// verify list, which would be worse than the bug being fixed.
  static bool disclaimsItself(Map hazard) {
    final text = [
      _str(hazard['name']),
      _str(hazard['description']),
      _str(hazard['visualEvidence']),
    ].join(' ');
    if (text.trim().length < 12) return false;
    return _anyMatch(_selfDisclaimCues, text);
  }

  /// Moves self-disclaimed rows out of `hazards` into [kVerifyOnSiteKey].
  ///
  /// Returns how many moved. They are NOT deleted: a distant corrosion lead is
  /// worth someone's attention, it is just not a non-conformance yet. The report
  /// prints them as inspection points, so the hazard count states what was
  /// actually confirmed.
  static int auditUnverifiable(
      Map<String, dynamic> result, List<Map<String, dynamic>> hazards) {
    final moved = <Map<String, dynamic>>[];
    hazards.removeWhere((h) {
      if (!disclaimsItself(h)) return false;
      h['verifyReason'] =
          'Moved out of the hazard table by the app: the finding itself states '
          'that this frame cannot confirm it. Recorded as a point to check on '
          'site, not as a non-conformance.';
      moved.add(h);
      return true;
    });

    if (moved.isEmpty) return 0;

    result[kVerifyOnSiteFlag] = true;
    final existing = result[kVerifyOnSiteKey];
    result[kVerifyOnSiteKey] = <Map<String, dynamic>>[
      if (existing is List)
        for (final e in existing)
          if (e is Map) e.cast<String, dynamic>(),
      ...moved,
    ];

    final note = '${moved.length} observation'
        '${moved.length == 1 ? '' : 's'} moved to "verify on site" — the '
        '${moved.length == 1 ? 'finding states' : 'findings state'} that this '
        'photograph cannot confirm ${moved.length == 1 ? 'it' : 'them'}.';
    final prior = _str(result['sceneNote']);
    result['sceneNote'] = prior.isEmpty ? note : '$prior $note';

    // The banner must follow the rows, exactly as in the two withdrawal audits.
    // This is the case the ore-bridge scan got wrong: its MEDIUM 38 came from a
    // row whose own description said the significance could not be determined.
    if (hazards.isEmpty) {
      final overall = _str(result['overallRisk']);
      if (overall.isNotEmpty && severityRank(overall) > severityRank('LOW')) {
        result['overallRiskBeforeSceneAudit'] = overall;
        result['overallRisk'] = 'LOW';
      }
      final score = _asInt(result['riskScore']);
      if (score != null && score > 15) {
        result['riskScoreBeforeSceneAudit'] = score;
        result['riskScore'] = 15;
      }
    }
    return moved.length;
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  ABSENCE CLAIMS
  // ═══════════════════════════════════════════════════════════════════════

  /// Words that turn a finding into a claim about something NOT being there.
  static final RegExp _absenceWord = RegExp(
    r'\b(no|not|non|none|without|missing|absent|lack(?:s|ing)?|lacked|'
    r'unprotected|unsecured|unguarded|uncovered|unfenced|unrailed|'
    r'inadequate|insufficient|improper|failure to provide|'
    r'devoid|bereft|bare)\b',
    caseSensitive: false,
  );

  /// The protective things a model most often declares missing. Restricted to
  /// items whose presence would be VISIBLE in a photograph, because those are
  /// the claims a reader can check and the ones that get this badly wrong.
  static final RegExp _protectiveThing = RegExp(
    r'\b(guard ?rails?|hand ?rails?|railings?|rails?|barriers?|barricades?|'
    r'toe ?boards?|guards?|guarding|covers?|fenc(?:e|es|ing)|mesh|nets?|'
    r'harness(?:es)?|lanyards?|fall (?:protection|arrest)|edge protection|'
    r'helmets?|hard ?hats?|goggles?|face ?shields?|gloves?|safety shoes?|'
    r'ppe|personal protective equipment|signage|warning signs?|'
    r'earthing|interlocks?|extinguishers?)\b',
    caseSensitive: false,
  );

  /// Hedges that make an absence "check" worthless. "Not clearly visible" is not
  /// evidence that a rail is missing — it is evidence that the model could not
  /// see, which is the opposite.
  static final RegExp _hedged = RegExp(
    r'(not clearly visible|not visible|cannot be seen|can not be seen|'
    r'unclear|appears to|seems to|may be|might be|could be|possibly|likely|'
    r'presumably|assumed|typical|typically|usually|generally|no specific|'
    r'difficult to (?:see|tell)|hard to (?:see|tell)|obscured|out of frame|'
    r'beyond the frame|not shown)',
    caseSensitive: false,
  );

  /// Numeric claims a single photograph cannot support. A stated "10+ meters
  /// above ground" is the tell of a model filling in a plausible number, and it
  /// is the figure a reader is most likely to quote in an incident file.
  static final RegExp _unmeasurable = RegExp(
    r'\b\d+(?:\.\d+)?\s*\+?\s*(?:m|mm|cm|metre|meter|metres|meters|ft|feet|foot|'
    r'kg|tonnes?|tons?|volts?|kv|v\b|amps?|deg(?:ree)?s?|°c|celsius|'
    r'psi|bar|db|decibels?)\b',
    caseSensitive: false,
  );

  /// Caps and flags an unsupported absence claim. Returns null when the hazard
  /// makes no absence claim, or makes one and supports it properly.
  static AbsenceVerdict? auditAbsenceClaim(Map<String, dynamic> hazard) {
    final name = _str(hazard['name']);
    final description = _str(hazard['description']);
    final evidence = _str(hazard['visualEvidence']);
    final check = _str(hazard['absenceCheck']);

    if (!claimsAbsence(name, description)) {
      // A hazard that makes no absence claim can still smuggle in a measurement
      // it cannot have taken, and that figure ends up quoted in an incident
      // file, so it is stripped of authority here too.
      final invented = _unmeasurable.firstMatch('$description $evidence');
      if (invented == null) return null;
      hazard['unmeasuredFigure'] = invented.group(0)!.trim();
      return AbsenceVerdict(
        severityChanged: false,
        issue: 'States "${invented.group(0)!.trim()}" — a single photograph '
            'cannot establish that figure. Measure on site before quoting it.',
      );
    }

    // What would count as support: the model saying where it looked and what it
    // found there, in enough words to be checkable, without hedging.
    final support = check.isNotEmpty ? check : evidence;
    final supported = support.trim().length >= 15 && !_hedged.hasMatch(support);

    if (supported) return null;

    final before = _str(hazard['severity']);
    final changed = severityRank(before) > severityRank(kUnprovenSeverity);
    if (changed) {
      hazard['severityBeforeAudit'] = before;
      hazard['severity'] = kUnprovenSeverity;
    }
    hazard['absenceUnconfirmed'] = true;
    final issue = check.isEmpty
        ? 'Claims a protection is missing but does not say where it looked. '
            'You cannot photograph a thing that is not there — confirm on site.'
        : 'The check for the missing protection is hedged '
            '("${_hedged.firstMatch(support)?.group(0) ?? support}"), '
            'so absence is not established. Confirm on site.';
    hazard['absenceIssue'] = issue;
    return AbsenceVerdict(severityChanged: changed, issue: issue);
  }

  /// Whether this finding's central claim is that something is not there.
  ///
  /// Both an absence word AND a visible protective thing must appear, and within
  /// reach of each other — "no entry beyond this point, guardrail painted
  /// yellow" contains both words and claims nothing missing.
  static bool claimsAbsence(String name, String description) {
    for (final text in [name, description]) {
      if (text.trim().isEmpty) continue;
      for (final m in _absenceWord.allMatches(text)) {
        // A window either side of the absence word, in characters. Wide enough
        // for "no permanent guardrail" and "guardrail is not provided",
        // narrow enough that two unrelated clauses do not pair up.
        const window = 60;
        final start = (m.start - window).clamp(0, text.length);
        final end = (m.end + window).clamp(0, text.length);
        if (_protectiveThing.hasMatch(text.substring(start, end))) return true;
      }
    }
    return false;
  }

  // ── shared helpers ────────────────────────────────────────────────────────

  static int severityRank(String severity) {
    final i = severityOrder.indexOf(severity.trim().toUpperCase());
    // An unknown label must not outrank a known one, nor be treated as the
    // mildest — it sits just below MEDIUM so it neither drives nor hides.
    return i < 0 ? 0 : i;
  }

  /// Normalised bbox as (x, y, w, h), accepting both the short and long key
  /// forms the prompt permits. Null when there is nothing usable.
  static ({double x, double y, double w, double h})? _bbox(dynamic bbox) {
    if (bbox is! Map) return null;
    final x = _asDouble(bbox['x']);
    final y = _asDouble(bbox['y']);
    final w = _asDouble(bbox['w'] ?? bbox['width']);
    final h = _asDouble(bbox['h'] ?? bbox['height']);
    if (x == null || y == null || w == null || h == null) return null;
    if (w <= 0 || h <= 0) return null;
    // Gemini's 0–1000 convention leaks through here as it does everywhere else.
    final scale = [x, y, w, h].reduce((a, b) => a > b ? a : b) > 1.0 ? 1000.0 : 1.0;
    return (x: x / scale, y: y / scale, w: w / scale, h: h / scale);
  }

  static double _iou(({double x, double y, double w, double h}) a,
      ({double x, double y, double w, double h}) b) {
    final x1 = a.x > b.x ? a.x : b.x;
    final y1 = a.y > b.y ? a.y : b.y;
    final x2 = (a.x + a.w) < (b.x + b.w) ? (a.x + a.w) : (b.x + b.w);
    final y2 = (a.y + a.h) < (b.y + b.h) ? (a.y + a.h) : (b.y + b.h);
    final iw = x2 - x1;
    final ih = y2 - y1;
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    final union = a.w * a.h + b.w * b.h - inter;
    return union <= 0 ? 0 : inter / union;
  }

  /// Jaccard overlap of meaningful words in the name and description.
  static double _textOverlap(Map a, Map b) {
    final sa = _tokens('${_str(a['name'])} ${_str(a['description'])}');
    final sb = _tokens('${_str(b['name'])} ${_str(b['description'])}');
    if (sa.isEmpty || sb.isEmpty) return 0;
    final inter = sa.intersection(sb).length;
    final union = sa.union(sb).length;
    return union == 0 ? 0 : inter / union;
  }

  /// Words too common in safety prose to signal anything. Without this, almost
  /// every pair of hazards looks similar because they all say "visible",
  /// "worker", "safety", "risk".
  static const Set<String> _stopWords = {
    'visible', 'the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to',
    'is', 'are', 'was', 'were', 'be', 'this', 'that', 'with', 'for', 'from',
    'by', 'as', 'it', 'its', 'there', 'has', 'have', 'no', 'not', 'any',
    'worker', 'workers', 'person', 'people', 'man', 'safety', 'risk', 'hazard',
    'hazardous', 'danger', 'dangerous', 'creating', 'creates', 'causing',
    'which', 'where', 'while', 'can', 'could', 'may', 'high', 'area', 'site',
  };

  static Set<String> _tokens(String s) => _norm(s)
      .split(' ')
      .where((w) => w.length > 2 && !_stopWords.contains(w))
      .toSet();

  static String _joinDistinct(String a, String b) {
    final first = a.trim();
    final second = b.trim();
    if (second.isEmpty) return first;
    if (first.isEmpty) return second;
    if (_norm(first).contains(_norm(second)) ||
        _norm(second).contains(_norm(first))) {
      return first.length >= second.length ? first : second;
    }
    final sep = first.endsWith('.') ? ' ' : '. ';
    return '$first$sep$second';
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static String _str(dynamic v) => v == null ? '' : v.toString().trim();

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v?.toString() ?? '');
  }

  static double? _asDouble(dynamic v) {
    if (v is num) {
      final d = v.toDouble();
      return d.isFinite ? d : null;
    }
    final p = double.tryParse(v?.toString() ?? '');
    return (p != null && p.isFinite) ? p : null;
  }
}

/// The outcome of auditing one hazard's absence claim.
class AbsenceVerdict {
  const AbsenceVerdict({required this.severityChanged, required this.issue});

  /// True when the severity was actually reduced (it was already LOW otherwise).
  final bool severityChanged;

  /// Plain-language explanation shown to the safety officer.
  final String issue;
}
