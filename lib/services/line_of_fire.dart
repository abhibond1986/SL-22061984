/// The one place that decides what a hazard's line of fire looks like
/// geometrically.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// The vision prompt asks for `lofZone` as a PATH: `{x1,y1}` is the energy
/// source and `{x2,y2}` is the exposed person. Two separate renderers then read
/// those same four numbers as a RECTANGLE — `Rect.fromLTRB(x1, y1, x2, y2)` on
/// screen, and a min/max box in the PDF. On screen that is worse than merely
/// imprecise: whenever the person stood above or to the left of the source the
/// rectangle came out inverted, a `width < 5` guard tripped, and the line of
/// fire was drawn as NOTHING. Roughly half of all findings disappeared silently,
/// and the ones that did draw showed a region rather than a direction — which is
/// the whole point of the concept.
///
/// Parsing now happens once, here, in pure Dart with no Flutter import, so it is
/// testable with the standalone VM and so the screen and the PDF cannot drift
/// apart again.
library;

import 'dart:math' as math;

/// A resolved line of fire: where the energy starts, who is in its path, and how
/// wide the danger corridor should be drawn.
///
/// All coordinates are normalised 0–1 against the displayed image, origin at the
/// TOP-LEFT (the convention the model is given and the convention Flutter uses).
/// The PDF renderer flips y itself — that belongs with the renderer, not here.
class LineOfFire {
  const LineOfFire({
    required this.sourceX,
    required this.sourceY,
    required this.personX,
    required this.personY,
    required this.width,
    required this.degenerate,
    this.exposure = '',
    this.source = '',
  });

  /// Centre of the energy source — the crane load, the nip point, the ladle.
  final double sourceX;
  final double sourceY;

  /// Centre of the person standing in the path.
  final double personX;
  final double personY;

  /// Corridor half-width at the PERSON end, as a fraction of the image's
  /// smaller dimension. The corridor tapers from a point at the source to this
  /// at the person, because that is how energy actually spreads — a swinging
  /// load or a jet of steam covers more ground the further it travels.
  final double width;

  /// True when source and person resolved to effectively the same point, so
  /// there is no direction to draw. The renderer shows a warning ring instead of
  /// an arrow rather than drawing a zero-length arrowhead pointing nowhere.
  final bool degenerate;

  /// Optional short phrase naming who or what is exposed, for the label.
  final String exposure;

  /// Short phrase naming the energy source at the tail of the arrow — the
  /// suspended coil, the reversing tipper, the open ladle. Never empty on a
  /// [LineOfFire] that [LineOfFireGeometry.parse] agreed to return: an arrow
  /// whose tail cannot be named points at nothing.
  final String source;

  /// Straight-line distance from source to person, normalised. Only meaningful
  /// as a rough magnitude — see [LineOfFireGeometry.plan] for real geometry,
  /// which must be done in pixels because the image is rarely square.
  double get length =>
      math.sqrt(math.pow(personX - sourceX, 2) + math.pow(personY - sourceY, 2));

  @override
  String toString() => 'LineOfFire(($sourceX,$sourceY) → ($personX,$personY) '
      'w=$width degenerate=$degenerate)';
}

/// A line of fire resolved into pixels for one particular display box.
class LofPlan {
  const LofPlan({
    required this.sourceX,
    required this.sourceY,
    required this.personX,
    required this.personY,
    required this.angle,
    required this.length,
    required this.halfWidth,
    required this.corridor,
    required this.degenerate,
  });

  final double sourceX, sourceY, personX, personY;

  /// Direction of travel in radians, y growing downward (screen convention).
  final double angle;

  /// Source-to-person distance in pixels.
  final double length;

  /// Corridor half-width at the person end, in pixels.
  final double halfWidth;

  /// Four corners, source end first, clockwise. Empty when [degenerate].
  final List<({double x, double y})> corridor;

  /// No usable direction — the renderer should mark the spot instead of drawing
  /// an arrow.
  final bool degenerate;
}

class LineOfFireGeometry {
  LineOfFireGeometry._();

  /// Below this normalised separation the two ends are treated as one point.
  /// A little over 3% of the image: closer than that and an arrowhead would be
  /// larger than the arrow, which reads as a smudge rather than a direction.
  static const double minSeparation = 0.035;

  /// Default corridor half-width when the model does not offer one. Chosen to be
  /// visible over a busy shop-floor photograph without hiding the equipment the
  /// safety officer needs to look at.
  static const double defaultWidth = 0.075;

  /// Hard bounds on corridor width. A model that returns a nonsense width must
  /// not be able to shade the entire photograph.
  static const double minWidth = 0.02;
  static const double maxWidth = 0.22;

  /// Beyond this normalised separation the "path" spans essentially the whole
  /// frame corner to corner. Real exposure is local — a load swings, a jet
  /// throws, a vehicle reverses — so a line this long is almost always a model
  /// drawing a stripe across the picture rather than tracing an energy path.
  /// The theoretical maximum is sqrt(2) ≈ 1.414, so this only rejects the
  /// genuinely frame-spanning case.
  static const double maxSeparation = 1.15;

  /// Things that can actually release energy at a person. The arrow's tail must
  /// be one of these; this is the whole basis of the concept.
  ///
  /// WHY THIS GATE EXISTS: a scan of an elevated walkway drew a line of fire
  /// down the length of the walkway from a worker to bare deck, labelled
  /// "worker on walkway". Nothing was at either end. A safety officer who
  /// follows two arrows like that stops following any of them, which costs the
  /// overlay its entire value on the photographs where it is right.
  static const List<String> energySourceWords = [
    // suspended and lifted loads
    'load', 'coil', 'slab', 'billet', 'bloom', 'crane', 'hoist', 'sling',
    'chain block', 'lifting', 'rigging', 'shackle', 'hook', 'skip', 'bucket',
    'grab', 'magnet', 'ladle', 'tundish', 'mould', 'ingot',
    // vehicles and mobile equipment
    'vehicle', 'truck', 'tipper', 'dumper', 'trailer', 'forklift', 'loader',
    'excavator', 'crawler', 'locomotive', 'wagon', 'trolley', 'bogie',
    'car', 'charging car', 'pushing ram', 'ram',
    // moving machine parts
    'conveyor', 'belt', 'pulley', 'drum', 'roller', 'roll', 'gear', 'shaft',
    'coupling', 'flywheel', 'fan', 'blower', 'impeller', 'blade', 'shear',
    'press', 'mill', 'saw', 'grinder', 'grinding wheel', 'agitator', 'mixer',
    'screw', 'nip point', 'pinch point', 'rotating', 'moving machine',
    // pressure, heat, molten and chemical release
    'hot metal', 'molten', 'slag', 'metal splash', 'splash', 'tapping',
    'furnace', 'converter', 'burner', 'flame', 'torch', 'steam', 'header',
    'pressuris', 'pressuriz', 'pressure', 'hydraulic', 'pneumatic',
    'compressed air', 'hose', 'valve', 'flange', 'bleeder', 'pipeline',
    'gas line', 'cylinder', 'acetylene', 'oxygen', 'chemical', 'acid',
    'caustic', 'nozzle', 'jet', 'relief', 'boiler', 'accumulator',
    // stored energy and instability
    'stack', 'stacked', 'stockpile', 'bundle', 'pile', 'spool', 'reel',
    'tensioned', 'spring', 'counterweight', 'suspended',
    // electrical
    'energised', 'energized', 'live', 'busbar', 'bus bar', 'switchgear',
    'transformer', 'panel', 'breaker', 'conductor', 'cable', 'terminal',
    'arc', 'electrical',
    // falling objects from above
    'falling object', 'overhead', 'above', 'loose material', 'debris from',
  ];

  /// Named sources that are NOT energy sources. Checked FIRST, because a model
  /// asked for a source will happily write "walkway" or "the worker" and those
  /// words would otherwise slip past on a partial match ('roll' inside
  /// 'rolling', 'above' inside a sentence about height).
  static const List<String> nonEnergySourceWords = [
    'walkway', 'pathway', 'path', 'gangway', 'passage', 'corridor', 'aisle',
    'floor', 'ground', 'deck', 'platform', 'edge', 'opening', 'gap', 'height',
    'elevation', 'fall', 'drop', 'stair', 'step', 'ladder', 'railing',
    'guardrail', 'handrail', 'barrier', 'worker', 'person', 'operator',
    'employee', 'man', 'himself', 'ppe', 'helmet', 'harness', 'housekeeping',
    'spill', 'clutter', 'scrap', 'signage', 'sign', 'training', 'procedure',
    'unknown', 'none', 'n/a', 'na', 'not visible', 'not applicable',
  ];

  /// Hazard wording that means the danger is the DROP or a gap in protection,
  /// not something travelling toward the person. These get a bounding box only.
  static final RegExp _boxOnlyHazard = RegExp(
    r'\b(fall(?:s|ing)? from|fall protection|fall arrest|fall hazard|'
    r'open edge|unprotected edge|edge protection|guard ?rail|hand ?rail|'
    r'railing|toe ?board|working at height|work at height|'
    r'ppe|personal protective|helmet|hard ?hat|goggles?|glove|safety shoe|'
    r'housekeeping|spill|slip|trip|clutter|obstruct|signage|'
    r'documentation|training|permit)\b',
    caseSensitive: false,
  );

  /// Whether this hazard names an energy source that could travel to the person.
  ///
  /// The order of these checks is the design:
  ///   1. An explicitly named source that is plainly NOT energy → reject. The
  ///      model has told us there is nothing at the arrow's tail.
  ///   2. An explicitly named source that IS energy → accept, even if the
  ///      hazard also mentions height. A rigger standing at an open edge under a
  ///      suspended coil is in the line of fire of the coil.
  ///   3. No source field at all (older cached reports, and models that ignore
  ///      the field) → fall back to the hazard's own wording, but only when that
  ///      wording is not itself a fall / PPE / housekeeping finding. This keeps
  ///      genuine historic overlays alive without letting the walkway case back
  ///      in.
  static bool namesEnergySource(Map hazard) {
    final zone = hazard['lofZone'];
    final named = _lower((zone is Map ? zone['source'] : null) ??
        hazard['lofSource'] ??
        '');

    if (named.isNotEmpty) {
      if (_containsWord(named, nonEnergySourceWords) &&
          !_containsWord(named, energySourceWords)) {
        return false;
      }
      if (_containsWord(named, energySourceWords)) return true;
      // Named, but unrecognised. Treated as a real source rather than discarded:
      // this vocabulary cannot possibly list every piece of plant in an
      // integrated steel works, and silently dropping an arrow the model was
      // specific about is the worse failure.
      return true;
    }

    final text = _lower('${hazard['name'] ?? ''} ${hazard['description'] ?? ''} '
        '${hazard['visualEvidence'] ?? ''} '
        '${zone is Map ? zone['exposure'] ?? '' : ''}');
    if (text.isEmpty) return false;
    if (!_containsWord(text, energySourceWords)) return false;
    // The hazard mentions machinery AND is fundamentally a fall/PPE finding —
    // e.g. "no handrail on the conveyor walkway". The conveyor is scenery here,
    // not the thing about to strike anyone.
    if (_boxOnlyHazard.hasMatch(text)) return false;
    return true;
  }

  /// A best-effort name for the arrow's tail, for the caption.
  static String describeSource(Map hazard) {
    final zone = hazard['lofZone'];
    final named = ((zone is Map ? zone['source'] : null) ??
            hazard['lofSource'] ??
            '')
        .toString()
        .trim();
    if (named.isNotEmpty) return named;
    final text = _lower('${hazard['name'] ?? ''} ${hazard['description'] ?? ''}');
    for (final w in energySourceWords) {
      if (_containsWord(text, [w])) return w;
    }
    return '';
  }

  static String _lower(Object v) =>
      v.toString().toLowerCase().replaceAll(RegExp(r'[^a-z0-9/]+'), ' ').trim();

  /// Whole-word (or word-prefix) containment. A bare `contains` is what lets
  /// "ppe" match "slippery" and "roll" match "controlled", so every candidate is
  /// anchored at a word boundary.
  static bool _containsWord(String text, List<String> words) {
    final padded = ' $text ';
    for (final w in words) {
      if (_boundedAfter(padded, w)) return true;
    }
    return false;
  }

  /// True when [w] appears at a word start and is followed only by a plural or
  /// gerund tail — so 'roll' matches 'rolls' and 'rolling' but not 'controlled'
  /// (wrong start) and not 'rollover' (unrelated word).
  static bool _boundedAfter(String padded, String w) {
    var from = 0;
    while (true) {
      final i = padded.indexOf(' $w', from);
      if (i < 0) return false;
      final after = i + 1 + w.length;
      final tail = padded.substring(after);
      if (tail.startsWith(' ') ||
          tail.startsWith('s ') ||
          tail.startsWith('es ') ||
          tail.startsWith('ing ') ||
          tail.startsWith('ed ')) {
        return true;
      }
      from = i + 1;
    }
  }

  /// Reads a hazard map and returns its line of fire, or null when the hazard
  /// has no usable path.
  ///
  /// Returning null is normal and expected — most hazards are not a line of
  /// fire. It must never throw: a malformed number from a model is not a reason
  /// to lose the whole annotated image.
  static LineOfFire? parse(Map hazard) {
    try {
      final zone = hazard['lofZone'];
      if (zone is! Map) return null;

      // An arrow needs something at its tail. Falls, PPE gaps and housekeeping
      // are real hazards and keep their bounding box — they just have no energy
      // travelling toward anyone, so there is no line of fire to draw.
      if (!namesEnergySource(hazard)) return null;

      var sx = _num(zone['x1']);
      var sy = _num(zone['y1']);
      var px = _num(zone['x2']);
      var py = _num(zone['y2']);
      if (sx == null || sy == null || px == null || py == null) return null;

      // Some models answer in 0–1000 (Gemini's box convention) even when asked
      // for 0–1. Any value above 1 can only be that, since the field is defined
      // as a fraction, so rescale rather than clamp everything to the edge —
      // clamping would pin every point to the bottom-right corner and draw a
      // confident arrow at entirely the wrong thing.
      final maxComponent = [sx, sy, px, py].reduce(math.max);
      if (maxComponent > 1.0) {
        final divisor = maxComponent > 100 ? 1000.0 : 100.0;
        sx /= divisor;
        sy /= divisor;
        px /= divisor;
        py /= divisor;
      }

      sx = sx.clamp(0.0, 1.0);
      sy = sy.clamp(0.0, 1.0);
      px = px.clamp(0.0, 1.0);
      py = py.clamp(0.0, 1.0);

      // Width is a fraction, so anything above 1 is either the 0–1000 scale or
      // nonsense. Values in between are not worth guessing at: a wrongly-wide
      // corridor shades equipment the officer needs to see, so an
      // uninterpretable width falls back to the default rather than being
      // clamped to an extreme.
      var width = _num(zone['width']) ?? _num(hazard['lofWidth']);
      if (width != null && width > 1.0) {
        width = width > 10.0 ? width / 1000.0 : null;
      }
      if (width != null && (width <= 0 || width > maxWidth * 2)) width = null;
      width = (width ?? defaultWidth).clamp(minWidth, maxWidth);

      final separation = math.sqrt(math.pow(px - sx, 2) + math.pow(py - sy, 2));
      // A stripe from one corner of the photograph to the other is not a path.
      if (separation > maxSeparation) return null;

      return LineOfFire(
        sourceX: sx,
        sourceY: sy,
        personX: px,
        personY: py,
        width: width,
        degenerate: separation < minSeparation,
        exposure: (zone['exposure'] ?? hazard['lofExposure'] ?? '')
            .toString()
            .trim(),
        source: describeSource(hazard),
      );
    } catch (_) {
      // A drawing overlay is never worth a crash.
      return null;
    }
  }

  /// Whether this hazard SHOULD have had a path. Used to flag a hazard that
  /// claims a line of fire but gives nothing to draw, which is otherwise
  /// invisible to the reader — the row says "Line of Fire" and the image shows
  /// no path, with no indication that anything is missing.
  static bool claimsLineOfFire(Map hazard) {
    final type = hazard['type']?.toString().toLowerCase() ?? '';
    if (type.contains('line of fire')) return true;
    final name = hazard['name']?.toString().toLowerCase() ?? '';
    return name.contains('line of fire');
  }

  /// Everything a renderer needs, already in PIXELS for a given display box.
  ///
  /// Geometry cannot be done in normalised space: a 4:3 photograph would skew
  /// the perpendicular offsets, so the corridor edges would not be parallel to
  /// the arrow and the arrowhead would sit at a visibly wrong angle. Both
  /// renderers therefore call this with their own box size and draw exactly what
  /// it returns.
  ///
  /// [boxW] and [boxH] are the pixel dimensions of the DISPLAYED image area,
  /// not the container — a letterboxed image would otherwise be annotated in
  /// the grey bars beside it.
  static LofPlan plan(LineOfFire lof, double boxW, double boxH) {
    final sx = lof.sourceX * boxW;
    final sy = lof.sourceY * boxH;
    final px = lof.personX * boxW;
    final py = lof.personY * boxH;

    // Width is expressed against the smaller dimension so a corridor occupies
    // the same visual share of a portrait and a landscape photo.
    final halfWidth = lof.width * math.min(boxW, boxH);

    final dx = px - sx;
    final dy = py - sy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (lof.degenerate || len < 1.0) {
      return LofPlan(
        sourceX: sx, sourceY: sy, personX: px, personY: py,
        angle: 0, length: len, halfWidth: halfWidth,
        corridor: const [], degenerate: true,
      );
    }

    final angle = math.atan2(dy, dx);
    // Unit normal, perpendicular to the direction of travel.
    final nx = -dy / len;
    final ny = dx / len;

    // The source end is narrow but NOT a true point: a triangle apex vanishes
    // against a detailed photograph, whereas a short base reads as "it starts
    // here". The person end is full width because that is where the energy
    // arrives and where the eye should land.
    final wSource = halfWidth * 0.28;

    return LofPlan(
      sourceX: sx, sourceY: sy, personX: px, personY: py,
      angle: angle, length: len, halfWidth: halfWidth,
      degenerate: false,
      corridor: [
        (x: sx + nx * wSource, y: sy + ny * wSource),
        (x: px + nx * halfWidth, y: py + ny * halfWidth),
        (x: px - nx * halfWidth, y: py - ny * halfWidth),
        (x: sx - nx * wSource, y: sy - ny * wSource),
      ],
    );
  }

  static double? _num(dynamic v) {
    if (v is num) {
      final d = v.toDouble();
      return d.isFinite ? d : null;
    }
    final parsed = double.tryParse(v?.toString() ?? '');
    return (parsed != null && parsed.isFinite) ? parsed : null;
  }
}
