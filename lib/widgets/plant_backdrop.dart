import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'safe_backdrop_filter.dart' show kLiteWebEffects;

/// Login background: the user's night-time steel plant illustration
/// (assets/images/login_backdrop.jpg, 1672 × 941; master in icon_src/), with
/// the smoke and the molten-metal pour brought to life on top of it.
///
/// History (2026-10-05): rev 1–5 drew a skyline in code. The user then
/// supplied this illustration and asked for "the animation for the smoke and
/// the flow of molten metal". The image is used as-is and a light animated
/// overlay is registered to its landmarks, in image pixels.
///
/// Motion (one seamless 12 s loop; every period divides 12 s):
///   * smoke puffs rising from both front chimneys along their painted plumes,
///     plus faint wisps from the far chimneys on the right;
///   * the molten stream: a flowing bright core with highlights travelling
///     down from the ladle lip to the moulds, a flickering glow at the lip and
///     the splash, and sparks thrown out from the splash;
///   * warm fume drifting up beside the moulds.
/// Reduced motion (OS setting) freezes a calm frame with no sparks.
///
/// The image and the overlay have their own RepaintBoundary; only the overlay
/// repaints per frame. Fit is BoxFit.cover anchored at the bottom, centred on
/// the pour, so the pour stays in view on wide and narrow screens.
class PlantBackdrop extends StatefulWidget {
  const PlantBackdrop({super.key, required this.isDark, this.animate = true});
  final bool isDark;

  /// False freezes the scene.
  final bool animate;

  /// Tests only: pin the loop at this point (0..1) and draw it as a live
  /// frame, so render tests can capture motion without a ticking animation.
  static double? debugFrame;

  static const asset = 'assets/images/login_backdrop.jpg';

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
    return widget.animate && !reduce && !kLiteWebEffects;
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
        // Same colours as the illustration's sky, so the instant before the
        // image decodes (and index.html before Flutter) look like one page.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Color(0xFF0A2CC8), Color(0xFF00226E), Color(0xFF0486B0)],
            ),
          ),
        ),
        RepaintBoundary(
          child: Image.asset(
            PlantBackdrop.asset,
            fit: BoxFit.cover,
            alignment: _Map.align,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            frameBuilder: (context, child, frame, sync) => sync
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    child: child),
          ),
        ),
        // Dark theme: a soft scrim so white text stays readable over the
        // busy upper half of the illustration (HUD lines, plumes); the plant
        // at the bottom is untouched.
        if (widget.isDark)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x8C020A2E), Color(0x66020A2E), Color(0x00020A2E)],
                stops: [0, 0.55, 0.8],
              ),
            ),
          ),
        // Light theme: the login's dark ink needs a pale veil over the night
        // sky. It fades out toward the bottom so the plant still shows.
        if (!widget.isDark)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xD9F2F4FF),
                  Color(0xC7EEF0FF),
                  Color(0x40EEF0FF),
                ],
                stops: [0, 0.62, 1],
              ),
            ),
          ),
        // Not on a mobile browser (2026-10-08): this painter issues ~60
        // MaskFilter.blur draws per frame, and Safari's HTML renderer turns
        // each one into a DOM element with a CSS blur. Re-created every frame
        // under the card's backdrop blur, that got the iPhone tab killed
        // ("A problem repeatedly occurred"). See safe_backdrop_filter.dart.
        // The illustration already has its smoke and pour painted in.
        if (!kLiteWebEffects)
          RepaintBoundary(
            child: CustomPaint(
              painter: _LifePainter(
                  t: _c, still: PlantBackdrop.debugFrame == null && !_run),
            ),
          ),
      ]);
}

// ─── Image registration ───────────────────────────────────────────────────
//
// Landmarks are in the illustration's own pixels (1672 × 941). [_Map]
// reproduces BoxFit.cover + [align] so the overlay lands exactly on them.
class _Map {
  static const double iw = 1672, ih = 941;

  /// Bottom-anchored; x slightly left of centre so that on a narrow phone the
  /// visible slice is centred on the pour (x ≈ 810).
  static const align = Alignment(-0.04, 1);

  static void apply(Canvas c, Size size) {
    final s = math.max(size.width / iw, size.height / ih);
    final ox = (size.width - iw * s) * (align.x + 1) / 2;
    final oy = (size.height - ih * s) * (align.y + 1) / 2;
    c.translate(ox, oy);
    c.scale(s);
  }
}

/// A chimney plume: where it leaves the stack, which way the painted plume
/// leans (per 100 px of rise), how tall it gets, and its size/strength.
class _Plume {
  const _Plume(this.top,
      {this.lean = -0.25, this.rise = 150, this.scale = 1, this.alpha = 1});
  final Offset top;
  final double lean, rise, scale, alpha;
}

const _plumes = <_Plume>[
  // Front-left tall chimney (red-lit top); painted plume leans up-left.
  _Plume(Offset(121, 327), lean: -0.22, rise: 165),
  // Second chimney.
  _Plume(Offset(338, 517), lean: -0.42, rise: 120, scale: 0.8),
  // Far chimneys on the right: small, faint (distance haze).
  _Plume(Offset(1638, 686), lean: -0.3, rise: 70, scale: 0.42, alpha: 0.55),
  _Plume(Offset(1352, 728), lean: -0.3, rise: 60, scale: 0.36, alpha: 0.5),
  _Plume(Offset(1374, 726), lean: -0.3, rise: 60, scale: 0.36, alpha: 0.5),
];

// The pour, traced from the painted stream.
const _lip = Offset(782, 785); // ladle lip
const _ctrl = Offset(814, 806); // quadratic control point
const _splash = Offset(828, 866); // where the stream meets the mould
const _fume = Offset(950, 850); // warm fume beside the moulds

const _tau = math.pi * 2;

class _Palette {
  static const smoke = Color(0xFFDDE6FF);
  static const fume = Color(0xFFFFB066);
  static const molten = Color(0xFFFF9A1F);
  static const hot = Color(0xFFFFD27A);
  static const white = Color(0xFFFFF6DE);
}

class _LifePainter extends CustomPainter {
  _LifePainter({required this.t, required this.still}) : super(repaint: t);
  final Animation<double> t;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final sec = t.value * 12;
    canvas.save();
    _Map.apply(canvas, size);
    for (var k = 0; k < _plumes.length; k++) {
      _smoke(canvas, sec, _plumes[k], k);
    }
    _fumes(canvas, sec);
    _pour(canvas, sec);
    canvas.restore();
  }

  // Puffs born at the stack every 6/8 s each, rising along the painted plume,
  // widening and fading. Periods: 6 s cycle (divides 12).
  void _smoke(Canvas canvas, double sec, _Plume p, int k) {
    const n = 8;
    for (var i = 0; i < n; i++) {
      final ph = ((sec / 6) + i / n + k * 0.17) % 1.0;
      final rise = ph * p.rise;
      final y = p.top.dy - 4 - rise;
      final x = p.top.dx +
          p.lean * rise * (0.6 + 0.6 * ph) +
          math.sin(ph * _tau * 1.5 + i) * 5 * p.scale;
      final r = (5 + ph * 26) * p.scale;
      final a = math.min(1.0, ph * 5) * math.pow(1 - ph, 1.4) * 0.30 * p.alpha;
      canvas.drawCircle(
          Offset(x, y),
          r,
          Paint()
            ..color = _Palette.smoke.withOpacity(a)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.6));
    }
  }

  // Warm fume rolling up beside the moulds (lit from below).
  void _fumes(Canvas canvas, double sec) {
    const n = 6;
    for (var i = 0; i < n; i++) {
      final ph = ((sec / 4) + i / n) % 1.0; // 4 s cycle
      final x = _fume.dx + (i.isEven ? 1 : -1) * 18 * ph + i * 6 - 15;
      final y = _fume.dy - ph * 90;
      final r = 14 + ph * 26;
      final a = math.sin(ph * math.pi) * 0.16;
      canvas.drawCircle(
          Offset(x, y),
          r,
          Paint()
            ..color = _Palette.fume.withOpacity(a)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.7));
    }
  }

  void _pour(Canvas canvas, double sec) {
    // Flicker: 1.2 s and 0.4 s periods, both divide 12 s.
    final flick = still
        ? 0.9
        : 0.85 +
            0.10 * math.sin(sec / 1.2 * _tau) +
            0.05 * math.sin(sec / 0.4 * _tau);

    // Breathing glow at the splash and the lip (additive, so it brightens
    // the painted glow instead of covering it).
    canvas.drawCircle(
        _splash,
        70,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = _Palette.molten.withOpacity(0.20 * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40));
    canvas.drawCircle(
        _lip,
        20,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = _Palette.hot.withOpacity(0.22 * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));

    // The stream, with a slight sway (period 2 s).
    final sway = still ? 0.0 : math.sin(sec / 2 * _tau) * 1.6;
    final stream = Path()
      ..moveTo(_lip.dx, _lip.dy)
      ..quadraticBezierTo(
          _ctrl.dx + sway, _ctrl.dy, _splash.dx + sway * 0.6, _splash.dy);
    canvas.drawPath(
        stream,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 16
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.plus
          ..color = _Palette.molten.withOpacity(0.28 * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawPath(
        stream,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round
          ..color = _Palette.white.withOpacity(0.80));

    // Highlights travelling down the stream: it visibly flows. Each takes
    // 0.6 s from lip to mould (divides 12 s).
    if (!still) {
      final metric = stream.computeMetrics().first;
      final len = metric.length;
      for (var i = 0; i < 4; i++) {
        final u = ((sec / 0.6) + i / 4) % 1.0;
        final start = (u * len) - 6;
        final seg = metric.extractPath(
            math.max(0, start), math.min(len, start + 14));
        canvas.drawPath(
            seg,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 7.5
              ..strokeCap = StrokeCap.round
              ..color = Colors.white.withOpacity(0.85)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
      }
    }

    // Sparks from the splash: ballistic, fading. Periods all divide 12 s.
    if (still) return;
    const periods = <double>[0.75, 1.0, 1.2, 1.5, 2.0];
    final spark = Paint()..blendMode = BlendMode.plus;
    for (var i = 0; i < 26; i++) {
      final period = periods[i % periods.length];
      final ph = ((sec / period) + i * 0.137) % 1.0;
      final tt = ph * period * 0.75; // seconds alive
      // Up-and-outward fan, biased to the right like the painted sparks.
      final ang = -math.pi / 2 + ((i * 0.618) % 1.0 - 0.38) * 2.3;
      final v = 90.0 + (i * 37 % 110);
      final pos = _splash +
          Offset(math.cos(ang) * v * tt,
              math.sin(ang) * v * tt + 0.5 * 320 * tt * tt);
      final life = 1 - ph;
      final r = 1.1 + (i % 3) * 0.45;
      spark
        ..color = Color.lerp(_Palette.white, _Palette.molten, ph)!
            .withOpacity(0.95 * life)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8);
      canvas.drawCircle(pos, r, spark);
    }

    // A thin bright rim where metal meets the mould (flickers).
    canvas.drawOval(
        Rect.fromCenter(center: _splash, width: 22, height: 6),
        Paint()
          ..color = _Palette.white.withOpacity(0.7 * flick)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
  }

  @override
  bool shouldRepaint(_LifePainter old) => old.still != still;
}
