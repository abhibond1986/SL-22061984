// Plain-VM regression tests for lib/services/hazard_quality.dart.
//
// Run with:  dart run tools/hazard_quality_test.dart
//
// Lives in tools/ rather than test/ on purpose: it imports no Flutter, so it
// runs in milliseconds with only the standalone Dart SDK. The rest of test/ is
// flutter_test style and needs the full toolchain.

import '../lib/services/hazard_quality.dart';

int _pass = 0;
int _fail = 0;

void ok(bool condition, String what) {
  if (condition) {
    _pass++;
  } else {
    _fail++;
    print('FAIL: $what');
  }
}

Map<String, dynamic> hz({
  String name = '',
  String description = '',
  String severity = 'HIGH',
  String? evidence,
  String? absenceCheck,
  Map<String, dynamic>? bbox,
  String? corrective,
  int? confidence,
}) =>
    <String, dynamic>{
      'name': name,
      'description': description,
      'severity': severity,
      if (evidence != null) 'visualEvidence': evidence,
      if (absenceCheck != null) 'absenceCheck': absenceCheck,
      if (bbox != null) 'bbox': bbox,
      if (corrective != null) 'correctiveAction': corrective,
      if (confidence != null) 'confidence': confidence,
    };

Map<String, dynamic> box(double x, double y, double w, double h) =>
    {'x': x, 'y': y, 'w': w, 'h': h};

void main() {
  // ── severity ranking ───────────────────────────────────────────────────
  ok(HazardQuality.severityRank('CRITICAL') > HazardQuality.severityRank('HIGH'),
      'CRITICAL outranks HIGH');
  ok(HazardQuality.severityRank('high') > HazardQuality.severityRank('MEDIUM'),
      'ranking is case-insensitive');
  ok(HazardQuality.severityRank('WHATEVER') == 0, 'unknown label ranks lowest');

  // ── family classification ──────────────────────────────────────────────
  ok(HazardQuality.familyOf(hz(name: 'Unprotected Fall Hazard')) == 'fall-edge',
      'fall hazard lands in fall-edge');
  ok(HazardQuality.familyOf(hz(name: 'Missing helmet')) == 'ppe-head-eye',
      'helmet lands in ppe-head-eye');
  ok(HazardQuality.familyOf(hz(name: 'Unguarded conveyor gear train')) ==
      'machine-guard', 'conveyor lands in machine-guard');
  ok(HazardQuality.familyOf(hz(name: 'Something entirely novel')) == null,
      'unclassifiable hazard has no family');

  // ── THE REGRESSION CASE: the walkway report ────────────────────────────
  // One alleged finding reported three times, which tripled the hazard count
  // and inflated the risk score.
  final walkway = <String, dynamic>{
    'hazards': [
      hz(
        name: 'Unprotected Fall Hazard',
        description:
            'Visible: worker walking along an elevated walkway with no guardrail '
            'on the open side, 10+ meters above ground level.',
        severity: 'CRITICAL',
        bbox: box(0.30, 0.20, 0.30, 0.60),
        corrective: 'Install permanent guardrails along the walkway.',
      ),
      hz(
        name: 'Unsecured Walkway Edge',
        description:
            'Visible: the walkway edge is unsecured and lacks edge protection.',
        severity: 'HIGH',
        bbox: box(0.32, 0.22, 0.30, 0.58),
        corrective: 'Provide toe boards at the edge.',
      ),
      hz(
        name: 'Inadequate Fall Protection',
        description:
            'Visible: worker without a safety harness while working at height.',
        severity: 'HIGH',
        bbox: box(0.34, 0.24, 0.28, 0.56),
        corrective: 'Issue full-body harness and anchor points.',
      ),
    ],
  };

  final report = HazardQuality.apply(walkway);
  final out = (walkway['hazards'] as List).cast<Map<String, dynamic>>();

  ok(out.length == 1, 'three overlapping fall findings merge into one '
      '(got ${out.length})');
  ok(report.merged == 2, 'report counts 2 merges (got ${report.merged})');
  ok(
      (out.first['mergedFrom'] as List).length == 3,
      'audit trail keeps all three original names '
      '(got ${out.first['mergedFrom']})');
  ok(
      (out.first['correctiveAction'] as String).contains('guardrail') &&
          (out.first['correctiveAction'] as String).contains('toe board') &&
          (out.first['correctiveAction'] as String).contains('harness'),
      'all three corrective actions survive the merge '
      '(got "${out.first['correctiveAction']}")');

  // The merged row asserts a missing guardrail with no stated check, so it is
  // capped at LOW and flagged rather than deleted.
  ok(out.first['severity'] == 'LOW',
      'unproven absence claim is capped at LOW (got ${out.first['severity']})');
  ok(out.first['severityBeforeAudit'] == 'CRITICAL',
      'the original severity is preserved for the reviewer');
  ok(out.first['absenceUnconfirmed'] == true, 'absence claim is flagged');
  ok((out.first['absenceIssue'] as String).isNotEmpty,
      'flag carries a plain-language reason');
  ok(report.absenceDowngraded == 1 && report.absenceFlagged == 1,
      'report counts the downgrade');
  ok(walkway[HazardQuality.kFlag] == true, 'result is marked checked');

  // ── merging must be conservative ───────────────────────────────────────
  final twoMachines = <String, dynamic>{
    'hazards': [
      hz(
        name: 'Unguarded rotating shaft',
        description: 'Visible: exposed rotating shaft on the left-hand drive.',
        bbox: box(0.05, 0.40, 0.15, 0.20),
        absenceCheck: 'The shaft housing is open; bare metal is visible turning.',
      ),
      hz(
        name: 'Unguarded rotating shaft',
        description: 'Visible: exposed rotating shaft on the right-hand drive.',
        bbox: box(0.75, 0.40, 0.15, 0.20),
        absenceCheck: 'The second housing is also open with bare shaft visible.',
      ),
    ],
  };
  HazardQuality.apply(twoMachines);
  ok((twoMachines['hazards'] as List).length == 2,
      'same family but non-overlapping boxes stay as two separate hazards');

  final differentFamilies = <String, dynamic>{
    'hazards': [
      hz(
          name: 'No helmet',
          description: 'Visible: worker bare-headed.',
          bbox: box(0.40, 0.10, 0.10, 0.10),
          absenceCheck: 'Head is uncovered; hair visible, no shell or brim.'),
      hz(
          name: 'Unguarded nip point',
          description: 'Visible: belt drive nip point exposed.',
          bbox: box(0.41, 0.11, 0.10, 0.10),
          absenceCheck: 'Drive guard bracket empty, belt and pulley exposed.'),
    ],
  };
  HazardQuality.apply(differentFamilies);
  ok((differentFamilies['hazards'] as List).length == 2,
      'overlapping boxes in DIFFERENT families are not merged');

  // Missing bbox falls back to wording overlap.
  final noBoxes = <String, dynamic>{
    'hazards': [
      hz(
          name: 'Oil spill on walkway floor',
          description: 'Visible: dark oil spill spreading across the walkway.'),
      hz(
          name: 'Oil spill creating slip risk',
          description: 'Visible: oil spill on the walkway floor, slippery.'),
    ],
  };
  HazardQuality.apply(noBoxes);
  ok((noBoxes['hazards'] as List).length == 1,
      'without boxes, near-identical wording merges');

  final noBoxesDistinct = <String, dynamic>{
    'hazards': [
      hz(
          name: 'Oil spill near pump house',
          description: 'Visible: dark oil pooled beside the pump discharge.'),
      hz(
          name: 'Scrap steel obstructing emergency exit',
          description:
              'Visible: cut plate offcuts stacked across the exit doorway.'),
    ],
  };
  HazardQuality.apply(noBoxesDistinct);
  ok((noBoxesDistinct['hazards'] as List).length == 2,
      'same family but unrelated wording stays separate');

  // Gemini's 0-1000 bbox convention must still overlap correctly.
  final thousandScale = <String, dynamic>{
    'hazards': [
      hz(
          name: 'Missing guardrail at platform edge',
          description: 'Visible: open platform edge.',
          bbox: box(300, 200, 300, 600)),
      hz(
          name: 'Unprotected platform edge',
          description: 'Visible: no railing along the platform.',
          bbox: box(320, 220, 300, 580)),
    ],
  };
  HazardQuality.apply(thousandScale);
  ok((thousandScale['hazards'] as List).length == 1,
      '0-1000 coordinates are normalised before the overlap test');

  // ── absence claims ─────────────────────────────────────────────────────
  ok(
      HazardQuality.claimsAbsence(
          'Unprotected edge', 'Visible: no guardrail on the open side.'),
      'detects a missing-guardrail claim');
  ok(
      HazardQuality.claimsAbsence('Worker without harness',
          'Visible: no fall arrest lanyard attached.'),
      'detects a missing-harness claim');
  ok(
      !HazardQuality.claimsAbsence('Oil spill on floor',
          'Visible: oil pooled across the walkway near the pump.'),
      'a positive observation is not an absence claim');
  ok(
      !HazardQuality.claimsAbsence('Damaged guardrail',
          'Visible: guardrail bent outward at the mid-span, weld cracked.'),
      'a damaged-but-present rail is not an absence claim');

  // A properly supported absence claim keeps its severity.
  final supported = hz(
    name: 'Missing guardrail at open edge',
    description: 'Visible: open edge of the platform.',
    severity: 'CRITICAL',
    absenceCheck: 'Followed the edge left to right across the full frame: '
        'bare concrete lip, no posts, no post sockets, no rail stubs.',
  );
  ok(HazardQuality.auditAbsenceClaim(supported) == null,
      'a specific, unhedged check leaves the hazard alone');
  ok(supported['severity'] == 'CRITICAL', 'supported claim keeps CRITICAL');

  // Hedged checks do not count as proof.
  final hedged = hz(
    name: 'Missing guardrail at open edge',
    description: 'Visible: open edge of the platform.',
    severity: 'CRITICAL',
    absenceCheck: 'The railing is not clearly visible in this image.',
  );
  final hv = HazardQuality.auditAbsenceClaim(hedged);
  ok(hv != null && hv.severityChanged, 'hedged check is downgraded');
  ok(hedged['severity'] == 'LOW', 'hedged absence claim ends at LOW');

  // Already-LOW claims are flagged but the severity does not "change".
  final alreadyLow = hz(
      name: 'No signage at entry',
      description: 'Visible: entry point.',
      severity: 'LOW');
  final lv = HazardQuality.auditAbsenceClaim(alreadyLow);
  ok(lv != null && !lv.severityChanged,
      'an already-LOW unproven claim is flagged without a severity change');
  ok(alreadyLow['absenceUnconfirmed'] == true, 'still flagged');

  // ── invented measurements ──────────────────────────────────────────────
  final measured = hz(
    name: 'Worker at elevated platform',
    description: 'Visible: worker standing on a platform 10+ meters above '
        'ground level.',
    severity: 'HIGH',
  );
  final mv = HazardQuality.auditAbsenceClaim(measured);
  ok(mv != null, 'an unmeasurable figure is flagged');
  ok(measured['unmeasuredFigure'] != null,
      'the offending figure is recorded (got ${measured['unmeasuredFigure']})');
  ok(measured['severity'] == 'HIGH',
      'a figure alone does not change severity — only the claim is annotated');

  final noFigure = hz(
    name: 'Worker at elevated platform',
    description: 'Visible: worker standing on an elevated walkway, several '
        'floors above the shop floor.',
    severity: 'HIGH',
  );
  ok(HazardQuality.auditAbsenceClaim(noFigure) == null,
      'qualitative height description is fine');

  // ── robustness ─────────────────────────────────────────────────────────
  final empty = <String, dynamic>{'hazards': <dynamic>[]};
  ok(!HazardQuality.apply(empty).changedAnything, 'empty hazard list is a no-op');

  final malformed = <String, dynamic>{'hazards': 'not a list'};
  ok(!HazardQuality.apply(malformed).changedAnything,
      'malformed hazards field is survived');

  final missing = <String, dynamic>{};
  ok(!HazardQuality.apply(missing).changedAnything, 'absent hazards field is survived');

  final junk = <String, dynamic>{
    'hazards': [
      <String, dynamic>{},
      'a bare string',
      hz(name: 'Oil spill', description: 'Visible: oil on floor.'),
    ],
  };
  HazardQuality.apply(junk);
  ok((junk['hazards'] as List).length == 2,
      'non-map entries are dropped, real hazards kept');

  // Idempotence: running twice must not merge or downgrade a second time.
  final twice = <String, dynamic>{
    'hazards': [
      hz(
          name: 'Unprotected Fall Hazard',
          description: 'Visible: no guardrail on the open side.',
          severity: 'CRITICAL',
          bbox: box(0.3, 0.2, 0.3, 0.6)),
      hz(
          name: 'Unsecured Walkway Edge',
          description: 'Visible: walkway edge lacks edge protection.',
          severity: 'HIGH',
          bbox: box(0.32, 0.22, 0.3, 0.58)),
    ],
  };
  HazardQuality.apply(twice);
  final second = HazardQuality.apply(twice);
  ok(!second.changedAnything, 'a second pass is a no-op');
  ok((twice['hazards'] as List).length == 1, 'still one hazard after two passes');
  ok(
      (twice['hazards'] as List).first['severityBeforeAudit'] == 'CRITICAL',
      'the recorded original severity is not overwritten by the second pass');

  // ── a box too large to locate anything ─────────────────────────────────
  //
  // The stockyard panorama's "Unguarded Elevated Walkway" box spanned ~90% of the
  // frame width. The hazard stays; only the drawing is withdrawn.
  final huge = hz(
      name: 'Unguarded Elevated Walkway',
      description: 'Visible: a truss walkway crosses the frame.',
      severity: 'CRITICAL',
      bbox: box(0.05, 0.30, 0.90, 0.34));
  ok(HazardQuality.auditBoxPrecision(huge), 'a frame-spanning box is withdrawn');
  ok(huge['bbox'] == null, 'the box is no longer drawn');
  ok(huge['bboxRejected'] != null, 'the rejected box is kept for inspection');
  ok(huge['locationUnpinned'] == true, 'the row says its location is unpinned');
  ok((huge['locationIssue'] as String).isNotEmpty, 'with a plain-language reason');
  ok(huge['severity'] == 'CRITICAL',
      'severity is NOT touched — this rule judges the box, not the finding');

  // A wide, shallow stripe fails on span even though its area is small.
  final stripe = hz(name: 'Spillage along belt line', bbox: box(0.02, 0.7, 0.95, 0.12));
  ok(HazardQuality.auditBoxPrecision(stripe),
      'a full-width stripe is withdrawn on span, not area');

  // A normal box, and one right at the edge of acceptable, are left alone.
  final tight = hz(name: 'Worker without helmet', bbox: box(0.41, 0.38, 0.12, 0.22));
  ok(!HazardQuality.auditBoxPrecision(tight), 'a locating box is left alone');
  ok(tight['bbox'] != null && tight['locationUnpinned'] == null,
      'and is not flagged');
  final borderline = hz(name: 'Stockpile face', bbox: box(0.1, 0.4, 0.55, 0.5));
  ok(!HazardQuality.auditBoxPrecision(borderline),
      'a large but still locating box (27% of frame) is kept');
  ok(!HazardQuality.auditBoxPrecision(hz(name: 'No box at all')),
      'a hazard with no box is not flagged');

  // Through the whole pass: counted, and the hazard is still in the list.
  final wide = <String, dynamic>{
    'hazards': [
      hz(
          name: 'Unguarded Elevated Walkway',
          description: 'Visible: a truss walkway crosses the frame.',
          severity: 'CRITICAL',
          evidence: 'The truss spans the width of the photograph.',
          absenceCheck: 'Looked along the full length of the deck; no rail seen.',
          bbox: box(0.05, 0.30, 0.90, 0.34)),
    ],
  };
  final wideReport = HazardQuality.apply(wide);
  ok(wideReport.boxesWithdrawn == 1, 'apply() counts the withdrawn box');
  ok(wideReport.changedAnything, 'and reports that something changed');
  ok((wide['hazards'] as List).length == 1, 'the hazard itself is kept');

  // ── a photograph that cannot be inspected ──────────────────────────────
  //
  // The stockyard panorama: three findings, a CRITICAL banner, and nothing in the
  // frame close enough to judge. The findings stay; the severities do not.
  final panorama = <String, dynamic>{
    'overallRisk': 'CRITICAL',
    'viewType': 'GENERAL_VIEW',
    'hazards': [
      hz(name: 'Conveyor gallery corrosion', severity: 'CRITICAL',
          bbox: box(0.1, 0.2, 0.5, 0.3)),
      hz(name: 'Fugitive dust plume', severity: 'HIGH'),
      hz(name: 'Housekeeping in yard', severity: 'LOW'),
    ],
  };
  final panReport = HazardQuality.apply(panorama);
  final panOut = (panorama['hazards'] as List).cast<Map<String, dynamic>>();
  ok(panorama[HazardQuality.kUninspectableFlag] == true,
      'a declared GENERAL_VIEW is flagged');
  ok(panReport.viewCapped == 2, 'both severities above MEDIUM are capped');
  ok(panOut.every((h) =>
          HazardQuality.severityRank(h['severity'] as String) <=
          HazardQuality.severityRank(HazardQuality.kUninspectableSeverity)),
      'nothing is left above MEDIUM');
  ok(panOut.first['severityBeforeViewCap'] == 'CRITICAL',
      "the model's own severity stays on the record");
  ok(panOut.last['severity'] == 'LOW', 'a LOW finding is not raised');
  ok(panorama['overallRisk'] == 'MEDIUM' &&
          panorama['overallRiskBeforeViewCap'] == 'CRITICAL',
      'the stored banner comes down with the rows');
  ok((panorama['viewCaveat'] as String).contains('pending site verification'),
      'the report says what the reader must do about it');
  ok(panOut.length == 3, 'no finding is deleted');

  // The model's own word is believed in both directions.
  ok(!HazardQuality.viewIsUninspectable(
          <String, dynamic>{'viewType': 'CLOSE_UP'}, [hz(name: 'x')]),
      'a declared CLOSE_UP is not capped');
  ok(HazardQuality.viewIsUninspectable(
          <String, dynamic>{'inspectable': false}, [hz(name: 'x')]),
      'inspectable: false is honoured on its own');

  // With no declaration, the boxes are the evidence.
  final unpinned = hz(name: 'Wide finding', bbox: box(0.02, 0.3, 0.95, 0.4));
  HazardQuality.auditBoxPrecision(unpinned);
  ok(HazardQuality.viewIsUninspectable(<String, dynamic>{}, [unpinned]),
      'a withdrawn box with nothing pinned anywhere reads as a general view');
  final alsoPinned = hz(name: 'Worker without helmet', bbox: box(0.4, 0.4, 0.1, 0.15));
  ok(!HazardQuality.viewIsUninspectable(<String, dynamic>{}, [unpinned, alsoPinned]),
      'one tightly-located box is enough to treat the photo as inspectable');
  ok(!HazardQuality.viewIsUninspectable(<String, dynamic>{}, [alsoPinned]),
      'ordinary boxes alone never trigger the cap');
  ok(!HazardQuality.viewIsUninspectable(<String, dynamic>{}, const []),
      'a scan with no hazards is not judged');

  // ── does the rule apply here at all? ──────────────────────────────────
  //
  // Fixture is the real report the user complained about: people seated in a
  // conference hall, "Missing PPE" at MEDIUM citing FA 1948 s.41C, in a scan
  // whose own summary said nothing hazardous was visible.
  final hall = <String, dynamic>{
    'sceneInventory': 'A conference hall with about twelve people seated around '
        'a long polished table. Laptops, notepads and water bottles on the '
        'table, a projection screen on the far wall, carpeted floor and a '
        'false ceiling with recessed lights.',
    'summary': 'No immediate physical hazards are clearly visible in the frame.',
    'overallRisk': 'MEDIUM',
    'riskScore': 38,
    'people': 12,
    'hazards': [
      hz(
        name: 'Missing PPE',
        description:
            'Visible: none of the seated persons is wearing a safety helmet or '
            'safety shoes, exposing them to head injury.',
        severity: 'MEDIUM',
        evidence: 'Bare heads of seated persons',
      ),
    ],
  };
  final hallReport = HazardQuality.apply(hall);
  final hallOut = (hall['hazards'] as List).cast<Map<String, dynamic>>();
  ok(HazardQuality.sceneIsNonIndustrial(hall),
      'a conference hall with no plant in it reads as non-industrial');
  ok(hallReport.sceneWithdrawn == 1, 'the PPE row is withdrawn');
  ok(hallOut.isEmpty, 'nothing is left in the hazard table');
  ok(hall[HazardQuality.kNonIndustrialFlag] == true, 'the scene flag is set');
  ok((hall[HazardQuality.kWithdrawnKey] as List).length == 1,
      'the withdrawn row is kept in the record, not deleted');
  ok(((hall[HazardQuality.kWithdrawnKey] as List).first
              as Map)['withdrawnReason']
          .toString()
          .contains('not required'),
      'the withdrawn row says why');
  ok(hall['overallRisk'] == 'LOW' &&
          hall['overallRiskBeforeSceneAudit'] == 'MEDIUM',
      'the banner follows the empty table down, with the original on record');
  ok(hall['riskScore'] == 15 && hall['riskScoreBeforeSceneAudit'] == 38,
      'the score follows too');
  ok(hallReport.changedAnything, 'the report admits it changed something');

  // A real finding in the same room is NOT withdrawn.
  final hallWithTrip = <String, dynamic>{
    'sceneInventory': 'A meeting room with a projector, upholstered chairs and '
        'a carpeted floor. An extension lead runs across the floor between the '
        'table and the wall socket.',
    'overallRisk': 'MEDIUM',
    'hazards': [
      hz(
        name: 'Trailing extension lead',
        description: 'Visible: an extension lead crosses the walkway between '
            'the table and the socket, a trip hazard for anyone leaving.',
        severity: 'MEDIUM',
        evidence: 'Extension lead across the carpet',
      ),
      hz(name: 'No safety goggles worn', description: 'Visible: bare eyes.'),
    ],
  };
  final tripReport = HazardQuality.apply(hallWithTrip);
  final tripOut = (hallWithTrip['hazards'] as List).cast<Map<String, dynamic>>();
  ok(tripReport.sceneWithdrawn == 1, 'only the PPE row goes');
  ok(tripOut.length == 1 && tripOut.first['name'] == 'Trailing extension lead',
      'a genuine office hazard survives');
  ok(hallWithTrip['overallRisk'] == 'MEDIUM',
      'the banner is left alone while any finding remains');

  // An industrial cue anywhere in the frame vetoes the whole rule.
  final controlRoom = <String, dynamic>{
    'sceneInventory': 'A control room with desks, monitors and office chairs. '
        'Through the window, an overhead crane is moving a ladle across the bay.',
    'overallRisk': 'HIGH',
    'hazards': [hz(name: 'Operators without helmets', severity: 'HIGH')],
  };
  final crReport = HazardQuality.apply(controlRoom);
  ok(!HazardQuality.sceneIsNonIndustrial(controlRoom),
      'a crane visible through the window vetoes the office reading');
  ok(crReport.sceneWithdrawn == 0, 'nothing is withdrawn there');
  ok((controlRoom['hazards'] as List).length == 1, 'the finding stands');

  // The model's own sceneType is believed when it gave one.
  ok(!HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneType': 'INDUSTRIAL',
        'sceneInventory': 'A conference hall with a projector and carpet.',
      }),
      'a declared INDUSTRIAL beats the office cues');
  ok(HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneType': 'OFFICE_OR_MEETING',
        'sceneInventory': 'Twelve persons at a table.',
      }),
      'a declared OFFICE_OR_MEETING needs no cue of its own');
  ok(!HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneType': 'OFFICE_OR_MEETING',
        'sceneInventory': 'A training hall with an acetylene cylinder and a '
            'gas cutting set laid out for a demonstration.',
      }),
      'a declared office containing plant is still not trusted');

  // Silence, not suppression: the rule must not fire on a shop floor, on a
  // scan that says nothing about where it is, or on a plain steel-plant frame.
  ok(!HazardQuality.sceneIsNonIndustrial(<String, dynamic>{}),
      'an empty result is never called non-industrial');
  ok(!HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneInventory': 'A worker at a lathe.',
      }),
      'a workshop frame is industrial');
  ok(!HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneInventory': 'Two men standing near a stack of steel plates in an '
            'open area under a clear sky.',
      }),
      'no office cue means the rule stays silent, not that it guesses');

  // The rule must not disarm itself: the prompt asks for the primary safety
  // concern in the summary, so the summary of a bad conference-hall scan says
  // "not wearing helmets" — and "helmet" is an industrial cue. If the veto read
  // the summary, every report this rule exists for would veto its own fix.
  ok(HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneInventory': 'A conference hall, people seated around a long table '
            'with laptops and a projection screen behind them.',
        'summary': 'Seated attendees are not wearing safety helmets or shoes, '
            'contrary to FA 1948 s.41C.',
      }),
      'a helmet mentioned only in the summary does not veto the office reading');
  ok(!HazardQuality.sceneIsNonIndustrial(<String, dynamic>{
        'sceneInventory': 'A conference hall with a projector, and a row of '
            'helmets and coveralls laid out on a side table.',
        'summary': 'Induction briefing before a shutdown.',
      }),
      'helmets actually IN the inventory still veto it');

  // "slippery" must not read as "ppe" here either — the same trap as dedupe.
  final wetOffice = <String, dynamic>{
    'sceneInventory': 'An office corridor with a carpeted floor and a water '
        'cooler. A slippery wet patch spreads from under the cooler.',
    'hazards': [
      hz(
        name: 'Slippery wet floor',
        description: 'Visible: a wet patch under the water cooler, no caution '
            'sign placed.',
        severity: 'MEDIUM',
        absenceCheck: 'Looked around the cooler and along the corridor; no '
            'caution sign or mat anywhere near the spill.',
      ),
    ],
  };
  final wetReport = HazardQuality.apply(wetOffice);
  ok(wetReport.sceneWithdrawn == 0,
      'a wet floor in an office is not a PPE finding and is not withdrawn');
  ok((wetOffice['hazards'] as List).length == 1, 'the spill is still reported');

  // ── normal by design ──────────────────────────────────────────────────
  //
  // From a real crane scan, 2026-09-07. The reporter's objection: the cabin is
  // bolted to the bridge by design, and a load is meant to hang from the hook.
  // Neither is a non-conformance unless something is wrong with it.
  final crane = <String, dynamic>{
    'sceneInventory': 'An overhead EOT crane bridge spanning a steel plant bay, '
        'with the operator cabin below the girder and a load on the hook. Blast '
        'furnace stacks are visible behind.',
    'overallRisk': 'MEDIUM',
    'riskScore': 35,
    'hazards': [
      hz(
        name: 'Operator cabin suspended at height',
        description: 'Visible: the crane operator cabin is suspended from the '
            'crane bridge above the bay floor.',
        severity: 'LOW',
        evidence: 'The cabin hangs beneath the bridge girder.',
      ),
      hz(
        name: 'Crane bridge walkway access',
        description: 'Visible: a walkway access runs along the crane bridge.',
        severity: 'LOW',
        evidence: 'Walkway visible along the girder.',
      ),
      hz(
        name: 'Suspended load over the bay',
        description: 'Visible: a load is suspended from the crane hook over the '
            'bay.',
        severity: 'LOW',
      ),
    ],
  };
  final craneReport = HazardQuality.apply(crane);
  ok(craneReport.normalWithdrawn == 3,
      'crane cabin, bridge walkway and suspended load are all withdrawn');
  ok((crane['hazards'] as List).isEmpty,
      'nothing was wrong in the frame, so no hazard is reported');
  ok((crane['withdrawnHazards'] as List).length == 3,
      'withdrawn rows are kept in the record, not deleted');
  ok(crane[HazardQuality.kNormalByDesignFlag] == true,
      'the result is flagged so a reader knows the app made a judgement');
  ok(crane['overallRisk'] == 'LOW',
      'the banner follows the rows down instead of stranding MEDIUM over an '
      'empty table');

  // The veto. Same features, now with something actually wrong with them —
  // these must all survive, because withdrawing one is a missed real defect.
  final craneDefects = <String, dynamic>{
    'sceneInventory': 'An overhead crane bridge in a steel plant bay.',
    'hazards': [
      hz(
        name: 'Missing handrail on cabin access walkway',
        description: 'Visible: the handrail is missing along the cabin access '
            'walkway on the crane bridge.',
        severity: 'HIGH',
      ),
      hz(
        name: 'Worker standing under suspended load',
        description: 'Visible: a worker is standing directly below the '
            'suspended load on the hook.',
        severity: 'CRITICAL',
      ),
      hz(
        name: 'Frayed sling on crane hook',
        description: 'Visible: the sling carrying the suspended load is frayed '
            'at the eye.',
        severity: 'HIGH',
      ),
      hz(
        name: 'Corroded crane walkway plate',
        description: 'Visible: the bridge walkway plate is corroded through '
            'near the end carriage.',
        severity: 'HIGH',
      ),
    ],
  };
  final defectReport = HazardQuality.apply(craneDefects);
  ok(defectReport.normalWithdrawn == 0,
      'a named defect on a designed feature vetoes the withdrawal');
  ok((craneDefects['hazards'] as List).length == 4,
      'all four genuine crane defects survive');

  // A person under the load is the exposure the reporter named explicitly.
  ok(
      !HazardQuality.describesNormalStateOnly(hz(
          name: 'Suspended load',
          description:
              'Visible: personnel walking beneath the suspended load.')),
      'a person beneath the load makes the lift a real hazard');
  ok(
      HazardQuality.describesNormalStateOnly(hz(
          name: 'Suspended load',
          description: 'Visible: a load suspended from the hook, no person in '
              'the vicinity.')),
      'the same lift with nobody under it is normal operation');

  // Unrelated findings in a crane bay must be untouched — the rule keys on the
  // row's own words, not on the scene being industrial.
  final craneBayOther = <String, dynamic>{
    'sceneInventory': 'A crane bay with material stacked on the floor.',
    'hazards': [
      hz(
        name: 'Oil spill on the bay floor',
        description: 'Visible: an oil spill spreads across the walking route.',
        severity: 'MEDIUM',
      ),
    ],
  };
  ok(HazardQuality.apply(craneBayOther).normalWithdrawn == 0,
      'an oil spill in a crane bay is not a design element');
  ok((craneBayOther['hazards'] as List).length == 1,
      'the spill is still reported');

  // An empty or near-empty row must not be withdrawn for being badly written.
  ok(!HazardQuality.describesNormalStateOnly(hz(name: '', description: '')),
      'an empty row is not treated as normal-by-design');

  // ── THE IDLE HOOK BLOCK ────────────────────────────────────────────────────
  // Regression for the gap found in the 2026-09-07 15:05 live scan: "Hanging
  // crane hook block ..." was filed at LOW on a build that already ran this
  // audit, because every cue in the lifting group named the LOAD and an idle
  // hook carries none.
  ok(
      HazardQuality.describesNormalStateOnly(hz(
          name: 'Hanging crane hook block',
          description: 'Visible: the crane hook block hangs at height over the '
              'bay with nothing attached to it.')),
      'an idle hook block parked at height is normal by design');
  ok(
      HazardQuality.describesNormalStateOnly(hz(
          name: 'Empty hook suspended above the floor',
          description: 'Visible: the bottom block of the hoist is suspended '
              'above the shop floor.')),
      'an empty suspended hook is not a finding on its own');
  // ...and the veto still wins, both for a defect on the hook and for a person
  // under it. These are the two cases the widened cue list must NOT swallow.
  ok(
      !HazardQuality.describesNormalStateOnly(hz(
          name: 'Hook block safety latch missing',
          description: 'Visible: the safety latch on the crane hook block is '
              'missing.')),
      'a defect on the hook block survives the widened cue list');
  ok(
      !HazardQuality.describesNormalStateOnly(hz(
          name: 'Hook block over occupied walkway',
          description: 'Visible: a worker is passing directly beneath the '
              'hanging hook block.')),
      'a person beneath the hook block survives the widened cue list');
  ok(
      !HazardQuality.describesNormalStateOnly(hz(
          name: 'Frayed wire rope on hoist drum',
          description: 'Visible: the wire rope hoist rope is frayed where it '
              'enters the rope drum.')),
      'a frayed rope on the hoist is a real defect, not a design element');

  print('');
  print('$_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail assertion(s) failed');
}
