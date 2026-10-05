import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Login background: a generic heavy-industry skyline at dusk, with slow
/// smoke from the chimneys and hot metal being poured inside an open bay.
///
/// History (2026-10-05): first a detailed steel-plant scene with an "AI scan"
/// sweep and hazard brackets; the user then asked for a *generic* industrial
/// background with smoke / hot metal and only a subtle, professional amount
/// of motion, so the scan and brackets were removed.
///
/// Drawn in code (sharp at any size, follows light/dark, no download weight).
///
/// Scene, back to front:
///   sky gradient, indigo and teal glows, a warm horizon glow
///   far:   low sawtooth sheds, a cooling tower, two slender chimneys
///   mid:   factory halls, process tower, storage tanks, silos and conveyor,
///          a melt shop with an open, lit bay, banded chimneys
///   near:  pipe rack on trestles, ground line
///
/// Motion (one seamless 12 s loop; every period divides 12 s):
///   * smoke rising and drifting from the chimneys, very low opacity;
///   * a molten stream from a tilted ladle in the open bay, with a gently
///     flickering glow and a few short-lived sparks at the splash;
///   * slow red aviation lights on the two tallest chimneys.
/// Reduced motion (OS setting) freezes a calm frame with no sparks.
///
/// The static skyline and the animated overlay are separate layers behind
/// their own RepaintBoundary; only the small overlay repaints per frame.
class PlantBackdrop extends StatefulWidget {
  const PlantBackdrop({super.key, required this.isDark, this.animate = true});
  final bool isDark;

  /// False freezes the scene.
  final bool animate;

  /// Tests only: pin the loop at this point (0..1) and draw it as a live
  /// frame, so render tests can capture motion without a ticking animation.
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
      _c.value = 0.3;
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
// Authored on a virtual 1600 × 420 strip whose bottom edge is the bottom of
// the screen: at least 34% of the screen height (so it reads on a tall
// phone), at least the screen width, centred. On wide screens it is
// flattened by up to 15% so it stays below the text.
class _Frame {
  _Frame(Size size) {
    final fit = size.height * 0.34 / vh;
    sx = math.max(size.width / vw, fit);
    sy = math.max(sx * 0.85, math.min(sx, fit));
    dx = (size.width - vw * sx) / 2;
    dy = size.height - vh * sy;
  }
  static const double vw = 1600, vh = 420;
  late final double sx, sy, dx, dy;

  void apply(Canvas c) {
    c.translate(dx, dy);
    c.scale(sx, sy);
  }
}

// Landmarks shared by both layers.
const _chimneys = <Offset>[
  Offset(262, 88),
  Offset(1036, 46),
  Offset(1100, 100),
  Offset(1376, 132),
];
const _beaconOn = <int>[1, 0]; // indexes into _chimneys that carry a light
const _bay = Rect.fromLTRB(752, 292, 912, 404); // open bay of the melt shop
const _lip = Offset(806, 322); // ladle pouring lip
const _splash = Offset(822, 398); // where the stream lands

class _Palette {
  _Palette(this.dark);
  final bool dark;
  List<Color> get sky => dark
      ? const [Color(0xFF151A4A), Color(0xFF10163D), Color(0xFF0B2A38)]
      : const [Color(0xFFE9ECFF), Color(0xFFF2F4FF), Color(0xFFE3F3F3)];
  Color get far => dark ? const Color(0xFF232B64) : const Color(0xFFD6DAF7);
  Color get mid => dark ? const Color(0xFF151B4A) : const Color(0xFFB0B7EA);
  Color get near => dark ? const Color(0xFF0C1135) : const Color(0xFF9199DB);
  Color get line => dark ? const Color(0xFF2E3878) : const Color(0xFFC6CBF2);
  Color get window => dark ? const Color(0xFFFFB547) : Colors.white;
  Color get bayInside =>
      dark ? const Color(0xFF2A1A1E) : const Color(0xFF8C7FA8);
  static const molten = Color(0xFFF59E0B);
  static const hot = Color(0xFFFFD27A);
  static const white = Color(0xFFFFF4D6);
}

// ─── Static skyline ───────────────────────────────────────────────────────
class _SkylinePainter extends CustomPainter {
  _SkylinePainter({required this.isDark});
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final p = _Palette(isDark);
    final rect = Offset.zero & size;

    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: p.sky,
          ).createShader(rect));

    final s = size.shortestSide;
    void glow(Offset c, double r, Color color) => canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.55));
    glow(Offset(size.width * 0.12, size.height * 0.10), s * 0.42,
        const Color(0xFF4F5BD5).withOpacity(isDark ? 0.48 : 0.26));
    glow(Offset(size.width * 0.92, size.height * 0.30), s * 0.38,
        const Color(0xFF0EA5B5).withOpacity(isDark ? 0.32 : 0.20));

    final f = _Frame(size);
    canvas.save();
    f.apply(canvas);

    // ── far layer ──
    final far = Paint()..color = p.far;
    _coolingTower(canvas, far, 1480, 420, 66, 168);
    canvas.drawRect(const Rect.fromLTWH(96, 150, 10, 270), far);
    canvas.drawRect(const Rect.fromLTWH(1250, 120, 9, 300), far);
    final shed = Path()..moveTo(0, 420);
    double x = 0;
    const heights = <double>[64, 84, 58, 78, 96, 62, 82, 70, 90, 60, 76];
    var i = 0;
    while (x < 1600) {
      final h = heights[i % heights.length];
      final w = 120.0 + (i * 37 % 60);
      shed.lineTo(x, 420 - h);
      for (var k = 0; k < 3; k++) {
        final tx = x + w * k / 3;
        shed
          ..lineTo(tx + w / 3 * 0.7, 420 - h - 12)
          ..lineTo(tx + w / 3 * 0.7, 420 - h)
          ..lineTo(tx + w / 3, 420 - h);
      }
      x += w;
      i++;
    }
    shed
      ..lineTo(1600, 420)
      ..close();
    canvas.drawPath(shed, far);

    // Warm horizon glow behind the mid layer (the works lit from within).
    canvas.drawOval(
        Rect.fromCenter(
            center: const Offset(830, 410), width: 1150, height: 240),
        Paint()
          ..color = _Palette.molten.withOpacity(isDark ? 0.18 : 0.12)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 70));

    // ── mid layer ──
    final mid = Paint()..color = p.mid;
    final pen = Paint()
      ..color = p.mid
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    // Factory hall, left, with a sawtooth roof.
    _sawHall(canvas, mid, 40, 330, 296, 4);
    // Process tower with platforms.
    canvas.drawRect(const Rect.fromLTWH(372, 168, 40, 252), mid);
    canvas.drawRect(const Rect.fromLTWH(386, 140, 12, 30), mid);
    final rail = Paint()
      ..color = p.line
      ..strokeWidth = 2;
    for (var y = 200.0; y < 400; y += 44) {
      canvas.drawRect(Rect.fromLTWH(362, y, 60, 5), mid);
      canvas.drawLine(Offset(362, y - 8), Offset(422, y - 8), rail);
    }
    // Storage tanks with domed tops.
    _tank(canvas, mid, 440, 92, 300);
    _tank(canvas, mid, 540, 76, 322);
    canvas.drawRect(const Rect.fromLTWH(430, 352, 200, 6), mid); // pipe

    // Melt shop: tall hall with a raised roof lantern and an open bay.
    final shop = Path()
      ..moveTo(650, 420)
      ..lineTo(650, 250)
      ..lineTo(830, 206)
      ..lineTo(1010, 250)
      ..lineTo(1010, 420)
      ..close();
    canvas.drawPath(shop, mid);
    canvas.drawRect(const Rect.fromLTWH(770, 190, 120, 26), mid); // lantern
    canvas.drawRect(Rect.fromLTWH(780, 198, 100, 6),
        Paint()..color = p.window.withOpacity(isDark ? 0.35 : 0.6));
    // The open bay: warm interior, lit from the pour.
    canvas.drawRect(_bay, Paint()..color = p.bayInside);
    canvas.drawRect(
        _bay,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0.0, 0.9),
            radius: 1.0,
            colors: [
              _Palette.molten.withOpacity(isDark ? 0.55 : 0.45),
              _Palette.molten.withOpacity(0),
            ],
          ).createShader(_bay));
    // Gantry beam and the tilted ladle hanging in the bay.
    canvas.drawRect(Rect.fromLTWH(_bay.left, _bay.top + 4, _bay.width, 6), mid);
    canvas.save();
    canvas.translate(_lip.dx - 26, _lip.dy + 4);
    canvas.rotate(-0.55);
    canvas.drawPath(
        Path()
          ..moveTo(-20, -14)
          ..lineTo(26, -14)
          ..lineTo(20, 24)
          ..lineTo(-14, 24)
          ..close(),
        mid);
    canvas.restore();
    canvas.drawLine(
        Offset(_lip.dx - 30, _bay.top + 10),
        Offset(_lip.dx - 30, _lip.dy - 12),
        Paint()
          ..color = p.mid
          ..strokeWidth = 2);
    // Runner / mould on the floor.
    canvas.drawRect(
        Rect.fromLTWH(_splash.dx - 34, _bay.bottom - 8, 68, 8), mid);
    // Hall windows.
    final win = Paint()..color = p.window.withOpacity(isDark ? 0.6 : 0.8);
    for (var wx = 668.0; wx < 740; wx += 22) {
      canvas.drawRect(Rect.fromLTWH(wx, 300, 10, 7), win);
      canvas.drawRect(Rect.fromLTWH(wx, 336, 10, 7), win);
    }
    for (var wx = 928.0; wx < 1000; wx += 22) {
      canvas.drawRect(Rect.fromLTWH(wx, 300, 10, 7), win);
    }

    // Chimneys, tapered, with painted bands.
    for (final top in _chimneys) {
      canvas.drawPath(
          Path()
            ..moveTo(top.dx - 8, top.dy)
            ..lineTo(top.dx + 8, top.dy)
            ..lineTo(top.dx + 14, 420)
            ..lineTo(top.dx - 14, 420)
            ..close(),
          mid);
      final band = Paint()..color = p.line;
      canvas.drawRect(Rect.fromLTWH(top.dx - 9, top.dy + 12, 18, 5), band);
      canvas.drawRect(Rect.fromLTWH(top.dx - 10, top.dy + 28, 20, 5), band);
    }

    // Silos with a conveyor gallery rising to their top.
    for (final sx in const <double>[1150, 1186, 1222]) {
      canvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(sx, 236, 32, 184),
              topLeft: const Radius.circular(6),
              topRight: const Radius.circular(6)),
          mid);
    }
    canvas.drawRect(const Rect.fromLTWH(1144, 224, 116, 14), mid);
    canvas.drawLine(const Offset(1250, 232), const Offset(1420, 360),
        pen..strokeWidth = 10);
    _truss(canvas, p.mid, const Offset(1252, 242), const Offset(1420, 370), 9);

    // Factory hall, right.
    _sawHall(canvas, mid, 1290, 1600, 318, 4);

    // Pipe bridge across the middle.
    canvas.drawRect(const Rect.fromLTWH(600, 344, 50, 5), mid);
    canvas.drawRect(const Rect.fromLTWH(1010, 344, 140, 5), mid);

    // ── near layer ──
    final near = Paint()..color = p.near;
    for (var tx = 20.0; tx < 1600; tx += 110) {
      canvas.drawRect(Rect.fromLTWH(tx, 380, 6, 40), near);
    }
    canvas.drawRect(const Rect.fromLTWH(0, 376, 1600, 5), near);
    canvas.drawRect(const Rect.fromLTWH(0, 388, 1600, 3), near);
    canvas.drawRect(const Rect.fromLTWH(0, 404, 1600, 40), near);
    canvas.drawRect(const Rect.fromLTWH(0, 410, 1600, 2),
        Paint()..color = p.line.withOpacity(0.7));

    canvas.restore();
  }

  void _sawHall(Canvas c, Paint paint, double x0, double x1, double y, int n) {
    final w = (x1 - x0) / n;
    final path = Path()
      ..moveTo(x0, 420)
      ..lineTo(x0, y);
    for (var k = 0; k < n; k++) {
      final a = x0 + w * k;
      path
        ..lineTo(a + w * 0.72, y - 22)
        ..lineTo(a + w * 0.72, y)
        ..lineTo(a + w, y);
    }
    path
      ..lineTo(x1, 420)
      ..close();
    c.drawPath(path, paint);
  }

  void _tank(Canvas c, Paint paint, double x, double w, double top) {
    c.drawRect(Rect.fromLTWH(x, top, w, 420 - top), paint);
    c.drawOval(Rect.fromLTWH(x, top - w * 0.16, w, w * 0.32), paint);
  }

  void _coolingTower(
      Canvas c, Paint paint, double cx, double base, double halfW, double h) {
    c.drawPath(
        Path()
          ..moveTo(cx - halfW, base)
          ..quadraticBezierTo(
              cx - halfW * 0.55, base - h * 0.7, cx - halfW * 0.62, base - h)
          ..lineTo(cx + halfW * 0.62, base - h)
          ..quadraticBezierTo(
              cx + halfW * 0.55, base - h * 0.7, cx + halfW, base)
          ..close(),
        paint);
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
        c.drawLine(p0 + unit, Offset.lerp(a, b, (k + 1) / bays)!, pen);
      }
    }
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

  static const _tau = 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    final sec = t.value * 12.0;
    final f = _Frame(size);
    canvas.save();
    f.apply(canvas);
    _smoke(canvas, sec);
    _pour(canvas, sec);
    _beacons(canvas, sec);
    canvas.restore();
  }

  // Soft plumes: seven puffs per chimney on a 6 s cycle, rising, widening and
  // leaning right with the wind. Very low opacity so it reads as atmosphere.
  void _smoke(Canvas canvas, double sec) {
    final tint = isDark ? const Color(0xFFC9CFF5) : const Color(0xFF7C85C9);
    for (var k = 0; k < _chimneys.length; k++) {
      final top = _chimneys[k];
      for (var i = 0; i < 7; i++) {
        final ph = ((sec / 6) + i / 7 + k * 0.13) % 1.0;
        final y = top.dy - 4 - ph * 120;
        final x = top.dx + ph * ph * 70 + math.sin(ph * _tau + k) * 4;
        final r = 6 + ph * 30;
        final a = math.min(1.0, ph * 6) * (1 - ph) * (isDark ? 0.17 : 0.16);
        canvas.drawCircle(
            Offset(x, y),
            r,
            Paint()
              ..color = tint.withOpacity(a)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.7));
      }
    }
  }

  // Hot metal: a slightly wavering stream from the ladle lip to the runner,
  // a breathing glow, and a few sparks thrown up at the splash.
  void _pour(Canvas canvas, double sec) {
    // Periods 1.2 s and 0.4 s both divide the 12 s loop, so it never jumps.
    final flick = still
        ? 0.9
        : 0.86 +
            0.09 * math.sin(sec / 1.2 * _tau) +
            0.05 * math.sin(sec / 0.4 * _tau);

    canvas.drawCircle(
        _splash,
        44,
        Paint()
          ..color = _Palette.molten.withOpacity((isDark ? 0.30 : 0.22) * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26));
    canvas.drawOval(
        Rect.fromCenter(center: _splash, width: 40, height: 8),
        Paint()
          ..color = _Palette.hot.withOpacity(0.85 * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));

    final wob = still ? 0.0 : math.sin(sec / 0.4 * _tau) * 0.8;
    final stream = Path()
      ..moveTo(_lip.dx, _lip.dy)
      ..quadraticBezierTo(_lip.dx + 14 + wob, _lip.dy + 20,
          _splash.dx + wob * 0.5, _splash.dy);
    canvas.drawPath(
        stream,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = _Palette.molten.withOpacity(0.35 * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawPath(
        stream,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.4
          ..strokeCap = StrokeCap.round
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_Palette.white, _Palette.hot, _Palette.molten],
          ).createShader(Rect.fromPoints(_lip, _splash)));

    if (still) return;
    // Sparks: twelve, each on a period that divides 12 s, short ballistic
    // arcs that fade out. Small and few, so the effect stays quiet.
    const periods = <double>[1.0, 1.2, 1.5, 2.0];
    for (var i = 0; i < 12; i++) {
      final period = periods[i % periods.length];
      final life = ((sec / period) + i * 0.37) % 1.0;
      if (life > 0.55) continue; // each spark is alive about half its cycle
      final l = life / 0.55;
      final ang = -math.pi / 2 + (((i * 0.61) % 1.0) - 0.5) * 2.2;
      final speed = 70.0 + (i * 23 % 40);
      final tt = l * 0.55;
      final pos = _splash +
          Offset(math.cos(ang) * speed * tt,
              math.sin(ang) * speed * tt + 0.5 * 260 * tt * tt);
      canvas.drawCircle(
          pos,
          1.3,
          Paint()
            ..color = _Palette.hot.withOpacity(0.9 * (1 - l))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8));
    }
  }

  // Red obstruction lights on the two tallest chimneys: slow 3 s blink.
  void _beacons(Canvas canvas, double sec) {
    for (final k in _beaconOn) {
      final ph = (sec / 3 + k * 0.5) % 1.0;
      final on = still ? 0.5 : (ph < 0.22 ? 1.0 : 0.18);
      final c = _chimneys[k] + const Offset(0, -3);
      canvas.drawCircle(
          c,
          8,
          Paint()
            ..color = const Color(0xFFFF4D4D).withOpacity(0.30 * on)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      canvas.drawCircle(c, 2.4,
          Paint()..color = const Color(0xFFFF6B6B).withOpacity(0.9 * on));
    }
  }

  @override
  bool shouldRepaint(_LifePainter old) =>
      old.isDark != isDark || old.still != still || old.t != t;
}
