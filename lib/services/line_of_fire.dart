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
