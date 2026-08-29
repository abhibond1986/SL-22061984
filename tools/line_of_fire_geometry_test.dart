// tools/line_of_fire_geometry_test.dart
//
// Geometry contract for lib/services/line_of_fire.dart.
//
// Deliberately plain Dart rather than a flutter_test file under test/: this
// module imports nothing but dart:math, so it runs on a bare Dart VM in
// milliseconds and can be checked without a Flutter toolchain at all —
//
//     dart run tools/line_of_fire_geometry_test.dart
//
// The case that matters most is "the case that used to vanish": when the exposed
// person stands above or to the left of the energy source, the old renderers
// built Rect.fromLTRB(x1,y1,x2,y2), got a negative width, and drew NOTHING — so
// the reader saw a clean photograph and concluded nobody was in danger.

import 'dart:math' as math;

import '../lib/services/line_of_fire.dart';
int fails = 0;
void ok(bool c, String what) {
  if (!c) { fails++; print('  FAIL  $what'); } else { print('  ok    $what'); }
}

void main() {
  print('parse');
  ok(LineOfFireGeometry.parse({}) == null, 'no lofZone -> null');
  ok(LineOfFireGeometry.parse({'lofZone': 'nonsense'}) == null, 'string zone -> null');
  ok(LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 0.1}}) == null, 'missing ends -> null');
  ok(LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': double.nan, 'y1': 0.1, 'x2': 0.2, 'y2': 0.2}}) == null, 'NaN -> null');

  final strs = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': '0.1', 'y1': '0.2', 'x2': '0.9', 'y2': '0.8'}})!;
  ok(strs.sourceX == 0.1 && strs.personY == 0.8, 'string numbers parse');

  final k = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 100, 'y1': 200, 'x2': 900, 'y2': 600}})!;
  ok((k.sourceX - 0.1).abs() < 1e-9 && (k.personX - 0.9).abs() < 1e-9, '0-1000 rescaled');

  final pct = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 10, 'y1': 20, 'x2': 90, 'y2': 60}})!;
  ok((pct.sourceX - 0.1).abs() < 1e-9, '0-100 rescaled');

  // widths
  for (final c in [(9.0, 0.075), (75.0, 0.075), (0.12, 0.12), (0.001, 0.02), (0.9, 0.075), (0.3, 0.22), (-1.0, 0.075)]) {
    final w = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 0.1, 'y1': 0.1, 'x2': 0.8, 'y2': 0.8, 'width': c.$1}})!.width;
    ok((w - c.$2).abs() < 1e-9, 'width ${c.$1} -> ${c.$2} (got $w)');
  }

  final deg = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 0.5, 'y1': 0.5, 'x2': 0.51, 'y2': 0.5}})!;
  ok(deg.degenerate, 'coincident ends are degenerate');

  ok(LineOfFireGeometry.claimsLineOfFire({'type': 'Line of Fire'}), 'claims by type');
  ok(LineOfFireGeometry.claimsLineOfFire({'name': 'LINE OF FIRE — load swing'}), 'claims by name');
  ok(!LineOfFireGeometry.claimsLineOfFire({'type': 'PPE'}), 'PPE does not claim');

  print('plan (the case that used to vanish)');
  // person ABOVE and LEFT of the source: Rect.fromLTRB gave negative width and
  // the old painter dropped the overlay entirely.
  final inv = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 0.85, 'y1': 0.85, 'x2': 0.15, 'y2': 0.15, 'width': 0.1}})!;
  final ip = LineOfFireGeometry.plan(inv, 400, 300);
  ok(!ip.degenerate && ip.corridor.length == 4, 'inverted still produces a corridor');
  ok(ip.length > 100, 'inverted has real length');
  ok(ip.personX < ip.sourceX && ip.personY < ip.sourceY, 'direction preserved, not normalised');
  ok((ip.angle - math.atan2(ip.personY - ip.sourceY, ip.personX - ip.sourceX)).abs() < 1e-12, 'angle matches source->person');

  print('plan geometry on a non-square box');
  final l = LineOfFireGeometry.parse({'lofZone': {'source': 'suspended load', 'x1': 0.2, 'y1': 0.2, 'x2': 0.8, 'y2': 0.75, 'width': 0.08}})!;
  final p = LineOfFireGeometry.plan(l, 400, 300);
  // corridor edges must be parallel to the arrow, or the drawing skews
  double ang(({double x, double y}) a, ({double x, double y}) b) =>
      math.atan2(b.y - a.y, b.x - a.x);
  ok((ang(p.corridor[0], p.corridor[1]) - p.angle).abs() < 0.35, 'left edge roughly follows travel');
  ok((ang(p.corridor[3], p.corridor[2]) - p.angle).abs() < 0.35, 'right edge roughly follows travel');
  // taper: source end narrower than person end
  double dist(({double x, double y}) a, ({double x, double y}) b) =>
      math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
  ok(dist(p.corridor[0], p.corridor[3]) < dist(p.corridor[1], p.corridor[2]),
     'corridor tapers from source to person');
  ok((p.halfWidth - 0.08 * 300).abs() < 1e-9, 'halfWidth measured against the SHORTER side');
  // every corner must be a real number
  ok(p.corridor.every((c) => c.x.isFinite && c.y.isFinite), 'all corners finite');

  print('the named-energy-source gate');
  Map<String, dynamic> zoneOnly(Map<String, dynamic> extra) => {
        ...extra,
        'lofZone': {
          'x1': 0.2, 'y1': 0.2, 'x2': 0.6, 'y2': 0.6,
          ...(extra['lofZone'] as Map<String, dynamic>? ?? {}),
        },
      };

  // The report that prompted this gate: an arrow down an empty walkway.
  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Unprotected Fall Hazard',
        'description': 'Visible: worker walking along an elevated walkway with '
            'no guardrail on the open side.',
        'lofZone': {'source': 'walkway', 'exposure': 'worker on walkway'},
      })) ==
          null,
      'a walkway is not an energy source -> no arrow');

  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Worker at open edge',
        'lofZone': {'source': 'the worker'},
      })) ==
          null,
      'the exposed person is not their own energy source -> no arrow');

  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Missing helmet',
        'description': 'Visible: worker bare-headed at the shop floor.',
        'lofZone': {'source': 'height'},
      })) ==
          null,
      'height is not an energy source -> no arrow');

  final coil = LineOfFireGeometry.parse(zoneOnly({
    'name': 'Rigger under suspended coil',
    'lofZone': {'source': 'suspended steel coil', 'exposure': 'rigger below'},
  }));
  ok(coil != null, 'a suspended coil IS an energy source -> arrow drawn');
  ok(coil?.source == 'suspended steel coil', 'source name is carried through');

  // A rigger under a load who ALSO stands at an open edge keeps the arrow: the
  // coil is what would strike them, whatever else is wrong with the platform.
  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Rigger at unprotected edge below load',
        'description': 'Visible: no guardrail at the platform edge; a suspended '
            'coil hangs directly above the rigger.',
        'lofZone': {'source': 'suspended coil'},
      })) !=
          null,
      'a named energy source wins over fall wording');

  // Unrecognised but specific: kept, because no word list can cover a whole
  // integrated steel works and dropping a specific answer is the worse failure.
  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Operator near descaler',
        'lofZone': {'source': 'hydro descaler manifold'},
      })) !=
          null,
      'an unrecognised but specific source is trusted');

  // No source field at all (older cached reports).
  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Worker beside running conveyor',
        'description': 'Visible: worker standing against a running belt '
            'conveyor with the drive drum exposed.',
      })) !=
          null,
      'no source field, but the hazard names a conveyor -> arrow kept');

  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'No handrail on conveyor walkway',
        'description': 'Visible: walkway alongside a conveyor with no handrail '
            'on the outboard side.',
      })) ==
          null,
      'machinery as scenery in a fall finding -> no arrow');

  ok(
      LineOfFireGeometry.parse(zoneOnly({
        'name': 'Poor housekeeping',
        'description': 'Visible: scrap and offcuts strewn across the floor.',
      })) ==
          null,
      'housekeeping gets a box only');

  ok(
      LineOfFireGeometry.parse({
        'name': 'Rigger under load',
        'lofZone': {
          'source': 'suspended coil',
          'x1': 0.01, 'y1': 0.01, 'x2': 0.99, 'y2': 0.99,
        },
      }) ==
          null,
      'a corner-to-corner stripe is rejected as absurd');

  ok(
      LineOfFireGeometry.parse({
        'name': 'Rigger under load',
        'lofZone': {
          'source': 'suspended coil',
          'x1': 0.10, 'y1': 0.15, 'x2': 0.80, 'y2': 0.70,
        },
      }) !=
          null,
      'a long but plausible path is kept');

  // The word-boundary trap that a bare `contains` walks straight into.
  ok(!LineOfFireGeometry.namesEnergySource({
        'name': 'Slippery floor near pump',
        'description': 'Visible: oil film making the floor slippery.',
      }),
      '"slippery" does not match the PPE/roll vocabulary by substring');
  ok(LineOfFireGeometry.namesEnergySource({
        'name': 'Operator beside rolls',
        'description': 'Visible: operator beside the exposed work rolls.',
      }),
      '"rolls" still matches "roll"');

  // ── the invented-person regression ──────────────────────────────────────
  //
  // A real report (AI scan of a coke-oven battery and stockyard, a distant wide
  // view with nobody discernible in it) printed "PEOPLE INVOLVED: 0" and then
  // drew three arrows labelled "potential worker on platform", "worker near
  // conveyor" and "worker near pile". The model's own answer already contained
  // the signal to suppress them. personVisible now carries that signal, and the
  // renderers draw a danger ZONE instead of an arrow when it is false.
  print('personVisible');

  Map<String, dynamic> crane(String exposure, {Object? people}) => {
        'name': 'Unguarded overhead crane',
        'severity': 'HIGH',
        'description': 'Visible: overhead crane travelling above the bay.',
        if (people != null) '_peopleVisible': people,
        'lofZone': {
          'source': 'crane load',
          'exposure': exposure,
          'x1': 0.30, 'y1': 0.20, 'x2': 0.55, 'y2': 0.62,
        },
      };

  ok(LineOfFireGeometry.parse(crane('rigger below load'))!.personVisible,
      'a named person who can be seen keeps the arrow');

  // The scan-level count wins over any wording: HazardQuality stamps it onto
  // every hazard as _peopleVisible before the renderers ever run.
  ok(!LineOfFireGeometry.parse(crane('rigger below load', people: 0))!
          .personVisible,
      'people: 0 overrides a confident-sounding exposure -> zone, not arrow');
  ok(LineOfFireGeometry.parse(crane('rigger below load', people: 2))!
          .personVisible,
      'people: 2 leaves the arrow alone');

  // The three wordings from the report itself.
  for (final e in [
    'potential worker on platform',
    'any worker in bay',
    'personnel could pass',
    'if a worker walks below',
    'would be struck',
    'workers may be present',
    'no person visible',
    'nobody',
    'unoccupied walkway',
    'n/a',
  ]) {
    ok(!LineOfFireGeometry.parse(crane(e))!.personVisible,
        'speculative exposure "$e" -> zone, not arrow');
  }

  // An empty exposure is treated as NOT visible on purpose. Nothing is lost:
  // the zone is drawn in exactly the place the arrow would have pointed, so the
  // hazard is still marked — only the claim "a person is standing here right
  // now" is withheld, which is the claim there is no evidence for.
  ok(!LineOfFireGeometry.parse(crane(''))!.personVisible,
      'an exposure the model left blank -> zone, not arrow');

  // An explicit flag from the model is honoured above everything else.
  ok(!LineOfFireGeometry.parse({
        'name': 'Unguarded overhead crane',
        'lofZone': {
          'source': 'crane load',
          'exposure': 'rigger below load',
          'personVisible': false,
          'x1': 0.3, 'y1': 0.2, 'x2': 0.55, 'y2': 0.62,
        },
      })!.personVisible,
      'lofZone.personVisible: false is honoured');

  // The zone must still be drawable — the hazard keeps its geometry.
  final zoneOnlyLof = LineOfFireGeometry.parse(crane('potential worker'))!;
  final zonePlan = LineOfFireGeometry.plan(zoneOnlyLof, 400, 300);
  ok(!zonePlan.degenerate && zonePlan.length > 10,
      'a no-person path still yields a plan the zone marker can use');

  print('pickOne (exactly one path per photograph)');
  ok(LineOfFireGeometry.pickOne([]) == null, 'no hazards -> nothing to draw');
  ok(LineOfFireGeometry.pickOne([
        {'name': 'Poor housekeeping'},
        'not a map',
      ]) == null,
      'no parseable path -> nothing to draw');

  Map<String, dynamic> path(String sev, String exposure, double y2,
          {Object? people}) =>
      {
        'name': 'Load handling',
        'severity': sev,
        'description': 'Visible: suspended load over the bay.',
        if (people != null) '_peopleVisible': people,
        'lofZone': {
          'source': 'suspended load',
          'exposure': exposure,
          'x1': 0.2, 'y1': 0.2, 'x2': 0.6, 'y2': y2,
        },
      };

  // The crane report's three arrows, with its own "PEOPLE INVOLVED: 0" applied.
  // One path is drawn, and it is the worst one.
  final three = [
    path('MEDIUM', 'potential worker on platform', 0.50, people: 0),
    path('CRITICAL', 'any worker near conveyor', 0.55, people: 0),
    path('HIGH', 'worker near pile', 0.60, people: 0),
  ];
  final picked = LineOfFireGeometry.pickOne(three)!;
  ok(picked.index == 1 && !picked.lof.personVisible,
      'with nobody visible, the CRITICAL path wins and is drawn as a zone');

  // Without that count, wording is all there is to go on: "worker near pile"
  // reads as an observation, so it is trusted and outranks the two speculative
  // paths even though one of them is CRITICAL. This is the intended order —
  // a drawable arrow on a real person tells the reader more than a zone does —
  // and it is why the scan-level people count matters so much.
  ok(LineOfFireGeometry.pickOne([
        path('MEDIUM', 'potential worker on platform', 0.50),
        path('CRITICAL', 'any worker near conveyor', 0.55),
        path('HIGH', 'worker near pile', 0.60),
      ])!.index == 2,
      'with no count, the one plainly-worded exposure is the one drawn');

  // A path with a real person outranks a more severe speculative one, because a
  // drawable arrow tells the reader more than a zone on a worse hazard does.
  final mixed = [
    path('CRITICAL', 'any worker near conveyor', 0.55),
    path('MEDIUM', 'rigger below load', 0.60),
  ];
  final mixedPick = LineOfFireGeometry.pickOne(mixed)!;
  ok(mixedPick.index == 1 && mixedPick.lof.personVisible,
      'a visible person beats a higher severity with nobody in it');

  print('caption (one shared wording for widget and PDF)');
  final vis = LineOfFireGeometry.parse(crane('rigger below load'))!;
  ok(LineOfFireGeometry.caption(0, vis) == '1  crane load → rigger below load',
      'visible: "<n>  <source> -> <who>"');
  ok(LineOfFireGeometry.caption(2, vis, arrow: '->') ==
          '3  crane load -> rigger below load',
      'the PDF gets an ASCII arrow: the bundled font has no glyph for U+2192');
  final unseen = LineOfFireGeometry.parse(crane('potential worker'))!;
  ok(LineOfFireGeometry.caption(0, unseen, arrow: '->')
          .contains('nobody in frame'),
      'no-person captions say so out loud instead of naming a worker');
  ok(!LineOfFireGeometry.caption(0, unseen, arrow: '->').contains('worker'),
      'and never repeat the invented "potential worker" wording');

  // ── the hallucinated-source regression ──────────────────────────────────
  //
  // A stockyard panorama produced a hazard called "Unguarded Elevated Walkway"
  // whose lofZone claimed `"source": "suspended steel coil"`. No coil existed
  // anywhere in the photograph, and the old gate passed it because "coil" is in
  // the energy vocabulary. A source now has to appear in the hazard's own
  // evidence.
  print('the source must be in the picture');

  ok(!LineOfFireGeometry.namesEnergySource({
        'name': 'Unguarded Elevated Walkway',
        'description': 'Visible: A large steel truss walkway spans across the '
            'image with no visible guardrails on the open side. The walkway is '
            'elevated several floors above ground level with open edges.',
        'lofZone': {'source': 'suspended steel coil'},
      }),
      'a coil nobody described -> no path, however energetic the word is');

  // "steel" is shared with the walkway description, and matching on it would let
  // the coil straight back in. Material and size words carry no identification.
  ok(!LineOfFireGeometry.sourceIsCorroborated({
        'name': 'Unguarded Elevated Walkway',
        'description': 'A large steel truss walkway.',
        'lofZone': {'source': 'large steel coil'},
      }),
      '"steel" and "large" alone do not corroborate anything');

  ok(LineOfFireGeometry.namesEnergySource({
        'name': 'Unsecured Suspended Load',
        'description': 'Visible: a suspended load hangs from the crane hook '
            'above the bay with no tag line.',
        'lofZone': {'source': 'suspended steel load'},
      }),
      'a source the description actually reports -> path kept');

  ok(LineOfFireGeometry.namesEnergySource({
        'name': 'Reversing tipper near stockpile',
        'description': 'Visible: a tipper truck reversing toward the pile.',
        'lofZone': {'source': 'reversing tipper'},
      }),
      'plural/verb tails still match ("tipper" in both)');

  // Unrecognised but corroborated: the vocabulary cannot list every machine in a
  // steel works, so a specific source the hazard also describes is trusted.
  ok(LineOfFireGeometry.namesEnergySource({
        'name': 'Open pusher ram path',
        'description': 'Visible: the pusher ram travels along the open track.',
        'lofZone': {'source': 'pusher ram'},
      }),
      'an unlisted machine the hazard describes is still trusted');

  // A source made only of generic words cannot be matched, so fall back to
  // asking whether the evidence names any energy source at all.
  ok(LineOfFireGeometry.sourceIsCorroborated({
        'name': 'Moving equipment',
        'description': 'Visible: an overhead crane travels above the aisle.',
        'lofZone': {'source': 'heavy machinery'},
      }),
      'an all-generic source falls back to the evidence vocabulary');
  ok(!LineOfFireGeometry.sourceIsCorroborated({
        'name': 'Poor housekeeping',
        'description': 'Visible: scrap strewn across the floor.',
        'lofZone': {'source': 'heavy machinery'},
      }),
      'an all-generic source with no energy in evidence -> not corroborated');

  // Unverifiable is not the same as contradicted. A hazard that arrived with no
  // description at all — an older cached report, or a salvaged partial answer —
  // cannot corroborate anything, so it is left alone rather than stripped.
  ok(LineOfFireGeometry.sourceIsCorroborated({
        'lofZone': {'source': 'suspended steel coil'},
      }),
      'no evidence text -> unverifiable, not rejected');

  // A name is a label, not an observation, so a hazard with no description cannot
  // contradict its source either — but a name that DOES mention the source still
  // corroborates it.
  ok(LineOfFireGeometry.sourceIsCorroborated({
        'name': 'Rigger under load',
        'lofZone': {'source': 'suspended coil'},
      }),
      'a name without a description cannot contradict a source');
  ok(LineOfFireGeometry.sourceIsCorroborated({
        'name': 'Rigger under suspended coil',
        'description': 'Visible: rigger standing in the drop zone.',
        'lofZone': {'source': 'suspended coil'},
      }),
      'a source named in the title counts as corroborated');

  // No source claimed at all is not a hallucination; the older text-based path
  // still decides those.
  ok(LineOfFireGeometry.sourceIsCorroborated({
        'name': 'Worker beside conveyor',
        'description': 'Visible: worker beside a running belt conveyor.',
      }),
      'no source claimed -> nothing to corroborate');

  print('');
  print(fails == 0 ? 'ALL PASS' : '$fails FAILURE(S)');
}
