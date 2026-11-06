// Plain-VM regression tests for the REQUIRED scan-level line-of-fire check
// (HazardQuality.auditLineOfFire / finaliseLineOfFire and the
// LineOfFireGeometry helpers the screen and PDF share).
//
// Run with:  dart run tools/line_of_fire_check_test.dart
//
// ★ 2026-11-06, user report: "sometimes line of fire appears in the image
// analysis and sometimes it doesn't". Each block below pins one of the
// behaviours that make it consistent.

import '../lib/services/hazard_quality.dart';
import '../lib/services/line_of_fire.dart';

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

Map<String, dynamic> path({
  String source = 'suspended steel coil',
  String energy = 'GRAVITY',
  double x1 = 0.50, double y1 = 0.20, double x2 = 0.52, double y2 = 0.72,
  bool personVisible = true,
  String exposure = 'rigger below load',
  String evidence = 'Coil hangs on taut slings well above the floor.',
}) =>
    {
      'source': source, 'energy': energy,
      'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'width': 0.08,
      'personVisible': personVisible, 'exposure': exposure,
      'evidence': evidence,
    };

Map<String, dynamic> scan(List<Map<String, dynamic>> hazards,
        {Object? lineOfFire, int people = 1, String overall = 'MEDIUM',
        String viewType = 'WORKING_DISTANCE'}) =>
    <String, dynamic>{
      'sceneInventory': 'EOT crane, steel coil on slings, rigger, bay floor.',
      'sceneType': 'INDUSTRIAL',
      'viewType': viewType,
      'inspectable': true,
      'overallRisk': overall,
      'riskScore': 40,
      'confidence': 80,
      'people': people,
      'summary': 'A coil is being lifted in the bay.',
      if (lineOfFire != null) 'lineOfFire': lineOfFire,
      'hazards': hazards,
    };

List<Map> rowsOf(Map r) => [
      for (final h in (r['hazards'] as List? ?? const [])) if (h is Map) h
    ];
Map checkOf(Map r) => r[LineOfFireGeometry.kCheckKey] as Map;
String verdictOf(Map r) => checkOf(r)['verdict'].toString();

Map<String, dynamic> housekeeping() => {
      'name': 'Scrap on walkway',
      'description': 'Visible: offcuts and scrap lying across the walkway '
          'beside the bay wall.',
      'severity': 'MEDIUM',
      'visualEvidence': 'Scrap offcuts on the walkway.',
      'correctiveAction': 'Clear the scrap and mark the walkway.',
      'bbox': {'x': 0.05, 'y': 0.70, 'w': 0.2, 'h': 0.15},
    };

void main() {
  // ── 1. A visible person in a path, and no row for it → a HIGH row is filed
  final r1 = scan([housekeeping()],
      lineOfFire: {'verdict': 'EXPOSED', 'paths': [path()]});
  HazardQuality.apply(r1);
  final filed = rowsOf(r1).where((h) => h['_derivedFrom'] == 'lineOfFire');
  ok(filed.length == 1, 'exposed person with no row: one row filed');
  ok(filed.isNotEmpty && filed.first['severity'] == 'HIGH',
      'filed row is HIGH');
  ok(filed.isNotEmpty && filed.first['type'] == 'Line of Fire',
      'filed row is typed Line of Fire');
  ok(filed.isNotEmpty &&
          filed.first['regulation'] == 'FA 1948 S111(1)(b)',
      'gravity path cites the under-a-suspended-load clause');
  ok(filed.isNotEmpty && LineOfFireGeometry.parse(filed.first) != null,
      'filed row carries a drawable path');
  ok(filed.isNotEmpty &&
          LineOfFireGeometry.parse(filed.first)!.personVisible,
      'filed row draws an ARROW (person visible)');
  ok(r1['overallRisk'] == 'HIGH', 'banner raised to HIGH');
  ok(verdictOf(r1) == LineOfFireGeometry.vExposed, 'verdict EXPOSED');
  ok(LineOfFireGeometry.checkLine(checkOf(r1)) == null,
      'a located path needs no status line');

  // ── 2. The model DID write a row for the source → path attached, no new row
  final crane = <String, dynamic>{
    'name': 'Rigger under suspended coil',
    'description': 'Visible: a rigger stands directly below a steel coil '
        'hanging from the crane hook.',
    'severity': 'HIGH',
    'visualEvidence': 'Coil on slings above the rigger.',
    'correctiveAction': 'Move the rigger clear and use tag lines.',
    'type': 'Line of Fire',
  };
  final r2 = scan([housekeeping(), crane],
      lineOfFire: {'verdict': 'EXPOSED', 'paths': [path()]});
  HazardQuality.apply(r2);
  ok(rowsOf(r2).length == 2, 'matching row exists: nothing filed');
  final craneRow =
      rowsOf(r2).firstWhere((h) => '${h['name']}'.contains('Rigger'));
  ok(LineOfFireGeometry.parse(craneRow) != null,
      'path attached to the row that names the coil');
  ok(LineOfFireGeometry.parse(rowsOf(r2)
          .firstWhere((h) => '${h['name']}'.contains('Scrap'))) ==
      null, 'path NOT attached to the unrelated housekeeping row');
  ok(checkOf(r2)['attached'] == 1, 'attach is counted');

  // ── 3. Nobody in frame → standalone danger zone, never a row
  final r3 = scan([housekeeping()], people: 0, lineOfFire: {
    'verdict': 'ZONE_ONLY',
    'paths': [
      path(personVisible: false, exposure: 'drop zone below load'),
    ],
  });
  HazardQuality.apply(r3);
  ok(rowsOf(r3).length == 1, 'zone-only adds no row');
  ok(verdictOf(r3) == LineOfFireGeometry.vZoneOnly, 'verdict ZONE_ONLY');
  final c3 = LineOfFireGeometry.collect(rowsOf(r3), check: checkOf(r3));
  ok(c3.length == 1 && c3.first.index == -1, 'zone collected as Z1');
  ok(c3.isNotEmpty && !c3.first.lof.personVisible, 'zone draws no arrow');
  final cap3 = c3.isEmpty ? '' : LineOfFireGeometry.caption(c3.first.index,
      c3.first.lof, arrow: '->');
  ok(cap3.startsWith('Z1') && cap3.contains('nobody in frame'),
      'zone caption is "Z1 … nobody in frame" ($cap3)');

  // ── 4. people = 0 overrides the model's personVisible: true
  final r4 = scan([housekeeping()], people: 0,
      lineOfFire: {'verdict': 'EXPOSED', 'paths': [path()]});
  HazardQuality.apply(r4);
  ok(rowsOf(r4).length == 1, 'people 0: no row filed despite the flag');
  ok(verdictOf(r4) == LineOfFireGeometry.vZoneOnly,
      'people 0: path kept as a zone');

  // ── 5. Hedged exposure wording never earns a filed row
  final r5 = scan([housekeeping()], lineOfFire: {
    'verdict': 'EXPOSED',
    'paths': [path(exposure: 'potential worker below')],
  });
  HazardQuality.apply(r5);
  ok(rowsOf(r5).length == 1, '"potential worker": no row filed');
  ok(verdictOf(r5) == LineOfFireGeometry.vZoneOnly,
      '"potential worker": drawn as a zone');

  // ── 6. NONE is an answer, and the report says so
  final r6 = scan([housekeeping()], lineOfFire: {
    'verdict': 'NONE',
    'reason': 'no load, vehicle or moving machinery in frame',
  });
  HazardQuality.apply(r6);
  ok(verdictOf(r6) == LineOfFireGeometry.vNone, 'verdict NONE');
  final line6 = LineOfFireGeometry.checkLine(checkOf(r6)) ?? '';
  ok(line6.startsWith('Checked') && line6.contains('no load'),
      'NONE prints "Checked - … (reason)"');
  ok(!line6.contains('—'), 'status line is ASCII for the PDF font');

  // ── 7. No answer at all → "not assessed", never silence
  final r7 = scan([housekeeping()]);
  HazardQuality.apply(r7);
  ok(verdictOf(r7) == LineOfFireGeometry.vNotReported, 'verdict NOT_REPORTED');
  ok((LineOfFireGeometry.checkLine(checkOf(r7)) ?? '').startsWith('Not assessed'),
      'NOT_REPORTED prints "Not assessed …"');
  ok(LineOfFireGeometry.checkLine(null, notReported: false) == null,
      'callers without a check keep the old silent behaviour');

  // ── 8. A non-energy "source" is rejected → NOT_LOCATED
  final r8 = scan([housekeeping()], lineOfFire: {
    'verdict': 'EXPOSED',
    'paths': [path(source: 'walkway')],
  });
  HazardQuality.apply(r8);
  ok(rowsOf(r8).length == 1, 'walkway as source: nothing filed');
  ok(verdictOf(r8) == LineOfFireGeometry.vNotLocated,
      'claimed but unusable path: NOT_LOCATED');

  // ── 9. A PPE row that mentions the crane is not where the path goes
  final ppe = <String, dynamic>{
    'name': 'Missing helmet',
    'description': 'Visible: rigger below the suspended coil has no helmet.',
    'severity': 'MEDIUM',
    'visualEvidence': 'Bare head of the rigger under the coil.',
    'correctiveAction': 'Issue and enforce helmets.',
  };
  final r9 = scan([ppe],
      lineOfFire: {'verdict': 'EXPOSED', 'paths': [path()]});
  HazardQuality.apply(r9);
  ok(LineOfFireGeometry.parse(rowsOf(r9)
          .firstWhere((h) => '${h['name']}'.contains('helmet'))) ==
      null, 'path not hung on a PPE row');
  ok(rowsOf(r9).any((h) => h['_derivedFrom'] == 'lineOfFire'),
      'its own line-of-fire row is filed instead');

  // ── 10. Idempotent across a forced re-run
  final n1 = rowsOf(r1).length;
  HazardQuality.apply(r1, force: true);
  ok(rowsOf(r1).length == n1, 'forced re-run files nothing twice');

  // ── 11. Person above-left of the source still draws (the inverted case)
  final r11 = scan([], lineOfFire: {
    'verdict': 'EXPOSED',
    'paths': [path(x1: 0.8, y1: 0.8, x2: 0.2, y2: 0.2,
        source: 'reversing dumper', energy: 'MOTION',
        exposure: 'worker behind dumper',
        evidence: 'Dumper on the haul road with reverse lamp lit.')],
  });
  HazardQuality.apply(r11);
  ok(rowsOf(r11).length == 1, 'empty table + exposed person: row filed');
  ok(rowsOf(r11).isNotEmpty &&
          rowsOf(r11).first['regulation'] == 'FA 1948 S7A(2)(d)',
      'vehicle path cites the plant-roads duty');
  final lof11 = rowsOf(r11).isEmpty ? null : LineOfFireGeometry.parse(rowsOf(r11).first);
  ok(lof11 != null && lof11.sourceX > lof11.personX,
      'inverted coordinates are kept, not reordered');

  // ── 12. A row that already carries its own lofZone is not duplicated
  final own = Map<String, dynamic>.from(crane)
    ..['lofZone'] = {
      'x1': 0.5, 'y1': 0.2, 'x2': 0.5, 'y2': 0.7,
      'source': 'suspended steel coil', 'exposure': 'rigger below load',
      'personVisible': true,
    };
  final r12 = scan([own],
      lineOfFire: {'verdict': 'EXPOSED', 'paths': [path()]});
  HazardQuality.apply(r12);
  ok(rowsOf(r12).length == 1, 'already-drawn path: no extra row');
  ok(LineOfFireGeometry.collect(rowsOf(r12), check: checkOf(r12)).length == 1,
      'already-drawn path: drawn once');

  // ── 13. Empty table, empty paths, NONE: verdict still recorded
  final r13 = scan([], lineOfFire: {'verdict': 'NONE', 'reason': 'office'});
  HazardQuality.apply(r13);
  ok(verdictOf(r13) == LineOfFireGeometry.vNone,
      'empty-table exit still finalises the verdict');

  // ── 14. A general view caps the filed row like any other
  final r14 = scan([], viewType: 'GENERAL_VIEW',
      lineOfFire: {'verdict': 'EXPOSED', 'paths': [path()]});
  r14['inspectable'] = false;
  HazardQuality.apply(r14);
  ok(rowsOf(r14).every((h) => h['severity'] != 'HIGH'),
      'general view: filed row capped');

  // ── 15. At most two paths are taken
  final r15 = scan([], people: 0, lineOfFire: {
    'verdict': 'ZONE_ONLY',
    'paths': [
      path(personVisible: false, exposure: 'drop zone'),
      path(personVisible: false, source: 'open ladle of hot metal',
          energy: 'THERMAL', exposure: 'splash zone', x1: 0.2, y1: 0.4,
          x2: 0.3, y2: 0.6, evidence: 'Ladle is open and glowing.'),
      path(personVisible: false, source: 'running belt conveyor',
          energy: 'ROTATING', exposure: 'nip zone', x1: 0.7, y1: 0.4,
          x2: 0.75, y2: 0.5, evidence: 'Belt is moving with material.'),
    ],
  });
  HazardQuality.apply(r15);
  ok((checkOf(r15)['zones'] as List).length == 2, 'at most two paths kept');

  print('');
  print('$_pass passed, $_fail failed');
  if (_fail > 0) throw StateError('$_fail assertion(s) failed');
}
