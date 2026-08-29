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

  print('');
  print('$_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail assertion(s) failed');
}
