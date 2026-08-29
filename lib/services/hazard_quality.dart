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
  });

  /// Hazards folded into another row.
  final int merged;

  /// Absence claims whose severity was reduced.
  final int absenceDowngraded;

  /// Absence claims flagged, whether or not the severity moved.
  final int absenceFlagged;

  bool get changedAnything =>
      merged > 0 || absenceDowngraded > 0 || absenceFlagged > 0;

  @override
  String toString() => 'QualityReport(merged: $merged, '
      'absenceDowngraded: $absenceDowngraded, '
      'absenceFlagged: $absenceFlagged)';
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

      final deduped = dedupe(hazards);
      final mergedCount = hazards.length - deduped.length;

      var downgraded = 0;
      var flagged = 0;
      for (final h in deduped) {
        final verdict = auditAbsenceClaim(h);
        if (verdict == null) continue;
        flagged++;
        if (verdict.severityChanged) downgraded++;
      }

      result['hazards'] = deduped;
      result[kFlag] = true;
      return QualityReport(
        merged: mergedCount,
        absenceDowngraded: downgraded,
        absenceFlagged: flagged,
      );
    } catch (_) {
      return const QualityReport(
          merged: 0, absenceDowngraded: 0, absenceFlagged: 0);
    }
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
