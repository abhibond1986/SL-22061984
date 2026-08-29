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

  print('');
  print(fails == 0 ? 'ALL PASS' : '$fails FAILURE(S)');
}
