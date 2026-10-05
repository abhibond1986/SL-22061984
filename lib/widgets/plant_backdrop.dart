import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Login background: a stylised integrated steel plant on the horizon
/// (2026-10-05, user request: "make a background image depending upon what
/// it is" + "add a little animation related to this app").
///
/// Drawn in code rather than shipped as a bitmap, so it is sharp at any size,
/// follows the light/dark theme, and adds nothing to the download size.
///
/// Scene, back to front:
///   sky gradient · indigo / teal glows · molten-amber horizon glow
///   far layer:  mill sheds with sawtooth roofs, two cooling towers
///   mid layer:  blast furnace + skip bridge, three hot-blast stoves, stacks,
///               conveyor gallery + junction tower, gasholder, ladle crane
///   near layer: pipe rack on trestles, rail line, ground
///
/// Motion (one loop, 12 s; all of it stops when the OS asks for reduced
/// motion):
///   * AI scan: a teal scan line sweeps the skyline, and as it passes the
///     ladle crane a hazard bracket locks on and fades. This is what the app
///     does: scan a scene, mark the hazard.
///   * smoke drifting from the stacks, aviation beacons blinking on their tops,
///     and a slow breathing of the furnace glow.
///
/// Only the animated overlay repaints each frame. The skyline is a separate
/// static layer behind its own RepaintBoundary.
class PlantBackdrop extends StatefulWidget {
  const PlantBackdrop({super.key, required this.isDark, this.animate = true});
  final bool isDark;

  /// False freezes the scene (reduced motion, tests that want a still).
  final bool animate;

  /// Tests only: pin the loop at this point (0..1) and draw it as a live
  /// frame, so render tests can capture the scan without a ticking animation.
  static double? debugFrame;

  @override
  State<PlantBackdrop> createState() => _PlantBackdropState();
}

class _PlantBackdropState extends State<PlantBackdrop>
    with SingleTickerProviderStateMixin {
  static const _loop = Duration(seconds: 12);
  late final AnimationController _c =
      AnimationController(vsync: this, duration: _loop);

  bool get _run {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return widget.animate && !reduce;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PlantBackdrop old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final freeze = PlantBackdrop.debugFrame;
    if (freeze != null) {
      _c.stop();
      _c.value = freeze;
      return;
    }
    if (_run) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
      // A still frame with no scan line visible.
      _c.value = 0.62;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        RepaintBoundary(
          child: CustomPaint(painter: _SkylinePainter(isDark: widget.isDark)),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _LifePainter(
                isDark: widget.isDark,
                t: _c,
                still: PlantBackdrop.debugFrame == null && !_run),
          ),
        ),
      ]);
}

// ─── Shared geometry ──────────────────────────────────────────────────────
//
// The skyline is authored on a virtual 1600 × 420 strip whose bottom edge is
// the bottom of the screen. It is scaled so it is at least 34% of the screen
// height (so it still reads on a tall phone) and at least the screen width,
// and is centred horizontally. On a phone that crops to the middle: the
// furnace, stoves and crane.
class _Frame {
  _Frame(Size size) {
    final fit = size.height * 0.34 / vh;
    sx = math.max(size.width / vw, fit);
    // On wide screens the width wins and the strip would grow tall enough to
    // reach the text; flatten it a little (at most 15%) to keep it low.
    sy = math.max(sx * 0.85, math.min(sx, fit));
    dx = (size.width - vw * sx) / 2;
    dy = size.height - vh * sy;
  }
  static const double vw = 1600, vh = 420;
  late final double sx, sy, dx, dy;

  Rect map(Rect r) => Rect.fromLTRB(
      dx + r.left * sx, dy + r.top * sy, dx + r.right * sx, dy + r.bottom * sy);

  void apply(Canvas c) {
    c.translate(dx, dy);
    c.scale(sx, sy);
  }
}

// Landmarks that the animated layer needs too.
const _stacks = <Offset>[Offset(430, 92), Offset(1062, 52), Offset(1212, 104)];
// Things the AI scan "marks" as it passes: the ladle crane (load overhead),
// the furnace top (gas / work at height) and the conveyor transfer tower
// (nip points). Whichever are on screen get a hazard bracket.
const _hazards = <Rect>[
  Rect.fromLTRB(166, 192, 362, 356),
  Rect.fromLTRB(704, 96, 842, 262),
  Rect.fromLTRB(1262, 214, 1360, 330),
];
const _furnaceTop = Offset(770, 118);

class _Palette {
  _Palette(this.dark);
  final bool dark;
  List<Color> get sky => dark
      ? const [Color(0xFF151A4A), Color(0xFF10163D), Color(0xFF0A2A38)]
      : const [Color(0xFFE9ECFF), Color(0xFFF2F4FF), Color(0xFFE3F3F3)];
  Color get far => dark ? const Color(0xFF262E6A) : const Color(0xFFD3D7F7);
  Color get mid => dark ? const Color(0xFF161C4C) : const Color(0xFFAEB5EA);
  Color get near => dark ? const Color(0xFF0C1135) : const Color(0xFF8D96DA);
  Color get line => dark ? const Color(0xFF3A4590) : const Color(0xFFC3C8F2);
  Color get window => dark ? const Color(0xFFFFB547) : const Color(0xFFFFFFFF);
  Color get molten => const Color(0xFFF59E0B);
}

// ─── Static skyline ───────────────────────────────────────────────────────
class _SkylinePainter extends CustomPainter {
  _SkylinePainter({required this.isDark});
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final p = _Palette(isDark);
    final rect = Offset.zero & size;

    // Sky.
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: p.sky,
          ).createShader(rect));

    // Brand glows, the same family as the rest of the login.
    final s = size.shortestSide;
    void glow(Offset c, double r, Color color) => canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.55));
    glow(Offset(size.width * 0.12, size.height * 0.10), s * 0.42,
        const Color(0xFF4F5BD5).withOpacity(isDark ? 0.50 : 0.26));
    glow(Offset(size.width * 0.92, size.height * 0.30), s * 0.38,
        const Color(0xFF0EA5B5).withOpacity(isDark ? 0.36 : 0.22));

    final f = _Frame(size);
    canvas.save();
    f.apply(canvas);

    // ── far layer ──
    final far = Paint()..color = p.far;
    _coolingTower(canvas, far, 150, 420, 64, 160);
    _coolingTower(canvas, far, 1400, 420, 70, 175);
    // Sawtooth-roofed mill sheds along the whole horizon.
    final shed = Path()..moveTo(0, 420);
    double x = 0;
    final heights = <double>[70, 92, 60, 84, 104, 66, 88, 74, 96, 62, 80];
    var i = 0;
    while (x < 1600) {
      final h = heights[i % heights.length];
      final w = 120.0 + (i * 37 % 60);
      shed.lineTo(x, 420 - h);
      // three roof teeth per shed
      for (var k = 0; k < 3; k++) {
        final tx = x + w * k / 3;
        shed.lineTo(tx + w / 3 * 0.7, 420 - h - 14);
        shed.lineTo(tx + w / 3 * 0.7, 420 - h);
        shed.lineTo(tx + w / 3, 420 - h);
      }
      x += w;
      i++;
    }
    shed
      ..lineTo(1600, 420)
      ..close();
    canvas.drawPath(shed, far);

    // ── molten horizon glow (between far and mid, so the plant is lit from behind) ──
    canvas.drawOval(
        Rect.fromCenter(center: const Offset(820, 400), width: 1100, height: 260),
        Paint()
          ..color = p.molten.withOpacity(isDark ? 0.22 : 0.16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 70));

    // ── mid layer ──
    final mid = Paint()..color = p.mid;
    final stroke = Paint()
      ..color = p.mid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;

    // Blast furnace: tapered shell, top platform, downcomers, skip bridge.
    final bf = Path()
      ..moveTo(720, 420)
      ..lineTo(728, 300)
      ..lineTo(712, 250)
      ..lineTo(742, 150)
      ..lineTo(798, 150)
      ..lineTo(828, 250)
      ..lineTo(812, 300)
      ..lineTo(820, 420)
      ..close();
    canvas.drawPath(bf, mid);
    canvas.drawRect(const Rect.fromLTWH(736, 128, 68, 22), mid); // top house
    canvas.drawRect(const Rect.fromLTWH(764, 104, 12, 26), mid); // bleeder
    // Downcomers: two big pipes curving down to the dust catcher.
    canvas.drawPath(
        Path()
          ..moveTo(790, 132)
          ..quadraticBezierTo(860, 120, 872, 230),
        stroke..strokeWidth = 9);
    canvas.drawPath(
        Path()
          ..moveTo(750, 132)
          ..quadraticBezierTo(690, 128, 676, 210),
        stroke..strokeWidth = 7);
    canvas.drawRect(const Rect.fromLTWH(656, 206, 40, 70), mid); // dust catcher
    canvas.drawPath(
        Path()
          ..moveTo(656, 276)
          ..lineTo(676, 300)
          ..lineTo(696, 276)
          ..close(),
        mid);
    // Skip bridge: inclined truss from the stockhouse to the furnace top.
    canvas.drawPath(
        Path()
          ..moveTo(540, 412)
          ..lineTo(744, 150),
        stroke..strokeWidth = 8);
    canvas.drawRect(const Rect.fromLTWH(500, 370, 90, 50), mid); // stockhouse
    _truss(canvas, p.mid, const Offset(540, 412), const Offset(744, 150), 14);

    // Three hot-blast stoves: tall domed cylinders.
    for (final sx in const <double>[880, 934, 988]) {
      final r = RRect.fromRectAndCorners(Rect.fromLTWH(sx, 196, 44, 224),
          topLeft: const Radius.circular(22), topRight: const Radius.circular(22));
      canvas.drawRRect(r, mid);
    }
    // Hot-blast main linking stoves to the furnace.
    canvas.drawRect(const Rect.fromLTWH(812, 330, 230, 9), mid);

    // Stacks (chimneys), tapered.
    for (final top in _stacks) {
      canvas.drawPath(
          Path()
            ..moveTo(top.dx - 9, top.dy)
            ..lineTo(top.dx + 9, top.dy)
            ..lineTo(top.dx + 15, 420)
            ..lineTo(top.dx - 15, 420)
            ..close(),
          mid);
      // Two painted bands near the top, as on real stacks.
      final band = Paint()..color = p.line;
      canvas.drawRect(Rect.fromLTWH(top.dx - 10, top.dy + 14, 20, 5), band);
      canvas.drawRect(Rect.fromLTWH(top.dx - 11, top.dy + 30, 22, 5), band);
    }

    // Conveyor gallery rising to a junction tower.
    canvas.drawPath(
        Path()
          ..moveTo(1100, 412)
          ..lineTo(1290, 262),
        stroke..strokeWidth = 12);
    _truss(canvas, p.mid, const Offset(1100, 420), const Offset(1290, 272), 10);
    canvas.drawRect(const Rect.fromLTWH(1280, 230, 64, 190), mid);
    canvas.drawRect(const Rect.fromLTWH(1272, 222, 80, 12), mid);

    // Gasholder.
    canvas.drawRRect(
        RRect.fromRectAndCorners(const Rect.fromLTWH(1440, 250, 120, 170),
            topLeft: const Radius.circular(10), topRight: const Radius.circular(10)),
        mid);
    final ribs = Paint()
      ..color = p.line
      ..strokeWidth = 2;
    for (var rx = 1452.0; rx < 1560; rx += 18) {
      canvas.drawLine(Offset(rx, 256), Offset(rx, 420), ribs);
    }

    // Ladle crane (gantry): two A-frame legs, girder, trolley, hook, ladle.
    _crane0(canvas, p);

    // Lit windows on the stockhouse, junction tower and furnace cast house.
    final win = Paint()..color = p.window.withOpacity(isDark ? 0.75 : 0.85);
    for (var wy = 244.0; wy < 400; wy += 26) {
      canvas.drawRect(Rect.fromLTWH(1292, wy, 8, 6), win);
      canvas.drawRect(Rect.fromLTWH(1322, wy + 8, 8, 6), win);
    }
    for (var wx = 508.0; wx < 584; wx += 18) {
      canvas.drawRect(Rect.fromLTWH(wx, 384, 8, 6), win);
    }
    canvas.drawRect(const Rect.fromLTWH(752, 380, 36, 10),
        Paint()..color = p.molten.withOpacity(isDark ? 0.85 : 0.65)); // taphole

    // ── near layer ──
    final near = Paint()..color = p.near;
    // Pipe rack on trestles across the whole width.
    for (var tx = 20.0; tx < 1600; tx += 110) {
      canvas.drawRect(Rect.fromLTWH(tx, 378, 6, 42), near);
    }
    canvas.drawRect(const Rect.fromLTWH(0, 374, 1600, 6), near);
    canvas.drawRect(const Rect.fromLTWH(0, 386, 1600, 4), near);
    // Ground with a rail line.
    canvas.drawRect(const Rect.fromLTWH(0, 404, 1600, 40), near);
    canvas.drawRect(Rect.fromLTWH(0, 410, 1600, 2),
        Paint()..color = p.line.withOpacity(0.7));

    canvas.restore();
  }

  void _coolingTower(Canvas c, Paint paint, double cx, double base,
      double halfW, double h) {
    // Hyperboloid silhouette: wide base, waist at ~70%, flared lip.
    final path = Path()
      ..moveTo(cx - halfW, base)
      ..quadraticBezierTo(cx - halfW * 0.55, base - h * 0.7,
          cx - halfW * 0.62, base - h)
      ..lineTo(cx + halfW * 0.62, base - h)
      ..quadraticBezierTo(cx + halfW * 0.55, base - h * 0.7, cx + halfW, base)
      ..close();
    c.drawPath(path, paint);
  }

  void _truss(Canvas c, Color color, Offset a, Offset b, int bays) {
    final pen = Paint()
      ..color = color
      ..strokeWidth = 2;
    final n = Offset(-(b.dy - a.dy), b.dx - a.dx);
    final unit = n / n.distance * 12;
    for (var k = 0; k <= bays; k++) {
      final p0 = Offset.lerp(a, b, k / bays)!;
      c.drawLine(p0, p0 + unit, pen);
      if (k < bays) {
        final p1 = Offset.lerp(a, b, (k + 1) / bays)!;
        c.drawLine(p0 + unit, p1, pen);
      }
    }
  }

  void _crane0(Canvas c, _Palette p) {
    final paint = Paint()..color = p.mid;
    final pen = Paint()
      ..color = p.mid
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    // Legs (A-frames).
    c.drawLine(const Offset(184, 420), const Offset(204, 214), pen);
    c.drawLine(const Offset(224, 420), const Offset(204, 214), pen);
    c.drawLine(const Offset(318, 420), const Offset(338, 214), pen);
    c.drawLine(const Offset(358, 420), const Offset(338, 214), pen);
    // Girder.
    c.drawRect(const Rect.fromLTWH(170, 200, 182, 16), paint);
    // Trolley + hook rope + ladle.
    c.drawRect(const Rect.fromLTWH(250, 216, 28, 14), paint);
    c.drawLine(const Offset(264, 230), const Offset(264, 300),
        Paint()
          ..color = p.mid
          ..strokeWidth = 2);
    c.drawPath(
        Path()
          ..moveTo(240, 300)
          ..lineTo(288, 300)
          ..lineTo(282, 344)
          ..lineTo(246, 344)
          ..close(),
        paint);
    // Molten rim of the ladle.
    c.drawRect(const Rect.fromLTWH(242, 298, 44, 4),
        Paint()..color = p.molten.withOpacity(p.dark ? 0.9 : 0.7));
  }

  @override
  bool shouldRepaint(_SkylinePainter old) => old.isDark != isDark;
}

// ─── Animated overlay ─────────────────────────────────────────────────────
class _LifePainter extends CustomPainter {
  _LifePainter({required this.isDark, required this.t, required this.still})
      : super(repaint: t);
  final bool isDark;
  final Animation<double> t;
  final bool still;

  static const _scanStart = 0.08, _scanEnd = 0.40; // of the 12 s loop

  @override
  void paint(Canvas canvas, Size size) {
    final p = _Palette(isDark);
    final sec = t.value * 12.0;
    final f = _Frame(size);
    canvas.save();
    f.apply(canvas);

    // Furnace glow breathing (6 s period).
    final breathe = 0.5 + 0.5 * math.sin(sec / 6 * 2 * math.pi);
    canvas.drawCircle(
        _furnaceTop,
        46,
        Paint()
          ..color = p.molten.withOpacity((isDark ? 0.10 : 0.07) + 0.08 * breathe)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30));

    // Smoke from each stack: five puffs per stack, rising and widening.
    final smoke = isDark ? Colors.white : const Color(0xFF6E78C8);
    for (var k = 0; k < _stacks.length; k++) {
      final top = _stacks[k];
      for (var i = 0; i < 5; i++) {
        final ph = ((sec / 7.5) + i / 5 + k * 0.17) % 1.0;
        final y = top.dy - 6 - ph * 110;
        final x = top.dx + ph * 46 + math.sin(ph * math.pi * 2 + k) * 6;
        final r = 7 + ph * 26;
        final a = (1 - ph) * math.min(1, ph * 5) * (isDark ? 0.10 : 0.12);
        canvas.drawCircle(
            Offset(x, y),
            r,
            Paint()
              ..color = smoke.withOpacity(a)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.6));
      }
    }

    // Aviation beacons: short red blink, staggered between stacks.
    for (var k = 0; k < _stacks.length; k++) {
      final ph = (sec / 1.6 + k * 0.33) % 1.0;
      final on = still ? 0.6 : (ph < 0.18 ? 1.0 : 0.15);
      final c = _stacks[k] + const Offset(0, -4);
      canvas.drawCircle(
          c,
          9,
          Paint()
            ..color = const Color(0xFFFF4D4D).withOpacity(0.35 * on)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawCircle(
          c, 2.6, Paint()..color = const Color(0xFFFF6B6B).withOpacity(0.95 * on));
    }

    canvas.restore();

    // AI scan sweep + hazard lock-on (screen space, so the line spans the
    // full visible width even when the skyline is cropped).
    if (!still) _scan(canvas, size, f, sec / 12.0);
  }

  void _scan(Canvas canvas, Size size, _Frame f, double u) {
    const teal = Color(0xFF22D3EE);
    const amber = Color(0xFFF59E0B);
    final skyTop = f.dy + 30 * f.sy; // just above the tallest stack

    if (u >= _scanStart && u <= _scanEnd) {
      final k = (u - _scanStart) / (_scanEnd - _scanStart);
      final e = Curves.easeInOutSine.transform(k);
      final x = -40 + (size.width + 80) * e;
      final fade = math.sin(k * math.pi); // in and out softly
      // Trail.
      final trail = Rect.fromLTRB(x - 160, skyTop, x, size.height);
      canvas.drawRect(
          trail,
          Paint()
            ..shader = LinearGradient(colors: [
              teal.withOpacity(0),
              teal.withOpacity((isDark ? 0.10 : 0.08) * fade),
            ]).createShader(trail));
      // Line.
      canvas.drawLine(
          Offset(x, skyTop),
          Offset(x, size.height),
          Paint()
            ..color = teal.withOpacity((isDark ? 0.75 : 0.6) * fade)
            ..strokeWidth = 1.6);
      canvas.drawLine(
          Offset(x, skyTop),
          Offset(x, size.height),
          Paint()
            ..color = teal.withOpacity(0.35 * fade)
            ..strokeWidth = 8
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }

    // Hazard brackets: each one locks on as the line passes it. Phones skip
    // them: there the skyline sits behind the card and the tiles.
    if (size.width < 600) return;
    for (final h in _hazards) {
      final box = f.map(h);
      if (box.center.dx < 8 || box.center.dx > size.width - 8) continue;
      final kHit = _inverseEase(
          ((box.center.dx + 40) / (size.width + 80)).clamp(0.0, 1.0));
      final uHit = _scanStart + kHit * (_scanEnd - _scanStart);
      final since = (u - uHit) * 12.0; // seconds since the line crossed
      if (since < 0 || since > 3.2) continue;
      _bracket(canvas, box, since, amber);
    }
  }

  void _bracket(Canvas canvas, Rect box, double since, Color amber) {
    final lock = Curves.easeOutBack.transform((since / 0.45).clamp(0.0, 1.0));
    final alpha = since < 2.4 ? 1.0 : (1 - (since - 2.4) / 0.8);
    final grow = 1.25 - 0.25 * lock; // brackets snap in from slightly wider
    final r = Rect.fromCenter(
        center: box.center, width: box.width * grow, height: box.height * grow);
    final pen = Paint()
      ..color = amber.withOpacity(0.9 * alpha)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final l = math.min(r.width, r.height) * 0.22;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final sx = c.dx == r.left ? 1.0 : -1.0;
      final sy = c.dy == r.top ? 1.0 : -1.0;
      canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy + sy * l)
            ..lineTo(c.dx, c.dy)
            ..lineTo(c.dx + sx * l, c.dy),
          pen);
    }
    // Soft fill while locked.
    canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(4)),
        Paint()..color = amber.withOpacity(0.07 * alpha * lock.clamp(0.0, 1.0)));
  }

  /// Inverse of Curves.easeInOutSine: x(k) = (1 - cos(pi k)) / 2.
  static double _inverseEase(double x) => math.acos(1 - 2 * x) / math.pi;

  @override
  bool shouldRepaint(_LifePainter old) =>
      old.isDark != isDark || old.still != still || old.t != t;
}
