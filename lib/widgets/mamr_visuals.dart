// lib/widgets/mamr_visuals.dart
//
// The visual vocabulary of MAMR, shared by Home and Reports so the two can
// never disagree about what a colour means:
//
//   complied        → green   (AppColors.green fill, sl.greenText ink)
//   pending, on time → amber
//   pending, overdue → red
//
// The one signature element is the compliance ring: one ring per area, and
// one big ring for the whole plant. Everything else stays quiet.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart' show AppColors, SL;
import '../services/mamr_service.dart';

const Color kMamrTeal = Color(0xFF0F766E);

/// Ring showing complied / pending-on-time / overdue as one circle, with the
/// complied % (or "—" when nothing was recorded) in the middle.
class MamrRing extends StatelessWidget {
  const MamrRing({
    super.key,
    required this.tally,
    this.size = 64,
    this.stroke = 7,
    this.caption,
  });

  final MamrTally tally;
  final double size;
  final double stroke;

  /// Small line under the percentage, e.g. "complied".
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final empty = tally.recorded == 0;
    final pct = empty ? '—' : '${tally.compliedPct.round()}%';
    return Semantics(
      label: empty
          ? 'No observations'
          : '${tally.complied} of ${tally.recorded} complied, '
            '${tally.pending} pending, ${tally.overdue} overdue',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(
            complied: tally.complied,
            onTime: tally.pending - tally.overdue,
            overdue: tally.overdue,
            track: sl.border,
            stroke: stroke,
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(pct,
                  style: TextStyle(
                      color: empty ? sl.text4 : sl.text1,
                      fontSize: size * 0.24,
                      fontWeight: FontWeight.w800,
                      height: 1.0)),
              if (caption != null && size >= 90) ...[
                const SizedBox(height: 3),
                Text(caption!,
                    style: TextStyle(color: sl.text3, fontSize: 11)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.complied,
    required this.onTime,
    required this.overdue,
    required this.track,
    required this.stroke,
  });

  final int complied, onTime, overdue;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(r, 0, math.pi * 2, false, base);
    final total = complied + onTime + overdue;
    if (total == 0) return;
    var start = -math.pi / 2;
    const gap = 0.04; // a hairline between segments so adjacent colours read
    for (final seg in [
      (complied, AppColors.green),
      (onTime, AppColors.amber),
      (overdue, AppColors.red),
    ]) {
      if (seg.$1 <= 0) continue;
      final sweep = math.pi * 2 * seg.$1 / total;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.butt
        ..color = seg.$2;
      final s = sweep > gap * 2 && total != seg.$1 ? sweep - gap : sweep;
      canvas.drawArc(r, start, s, false, p);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.complied != complied || o.onTime != onTime ||
      o.overdue != overdue || o.track != track;
}

/// Thin stacked bar: complied | pending on time | overdue.
class MamrBar extends StatelessWidget {
  const MamrBar({super.key, required this.tally, this.height = 8});
  final MamrTally tally;
  final double height;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final onTime = tally.pending - tally.overdue;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: tally.recorded == 0
            ? ColoredBox(color: sl.border)
            : Row(children: [
                if (tally.complied > 0)
                  Expanded(flex: tally.complied,
                      child: const ColoredBox(color: AppColors.green)),
                if (onTime > 0)
                  Expanded(flex: onTime,
                      child: const ColoredBox(color: AppColors.amber)),
                if (tally.overdue > 0)
                  Expanded(flex: tally.overdue,
                      child: const ColoredBox(color: AppColors.red)),
              ]),
      ),
    );
  }
}

/// A number with its label underneath, coloured by meaning.
class MamrFigure extends StatelessWidget {
  const MamrFigure({
    super.key,
    required this.value,
    required this.label,
    this.ink,
    this.big = false,
  });
  final String value;
  final String label;
  final Color? ink;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min, children: [
      Text(value,
          style: TextStyle(
              color: ink ?? sl.text1,
              fontSize: big ? 24 : 17,
              fontWeight: FontWeight.w800,
              height: 1.1)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: sl.text3, fontSize: 12)),
    ]);
  }
}

/// The colour key, shown once per screen rather than on every row.
class MamrLegend extends StatelessWidget {
  const MamrLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    Widget dot(Color c, String l) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(l, style: TextStyle(color: sl.text3, fontSize: 12)),
        ]);
    return Wrap(spacing: 14, runSpacing: 6, children: [
      dot(AppColors.green, 'Complied'),
      dot(AppColors.amber, 'Pending'),
      dot(AppColors.red, 'Overdue'),
    ]);
  }
}

/// Plain-language status line for a tally: "All 5 complied",
/// "2 pending, 1 overdue", "No observations".
String mamrStatusLine(MamrTally t) {
  if (t.recorded == 0) return 'No observations';
  if (t.pending == 0) {
    return t.recorded == 1 ? 'Complied' : 'All ${t.recorded} complied';
  }
  final parts = <String>[
    '${t.pending} pending',
    if (t.overdue > 0) '${t.overdue} overdue',
  ];
  return '${parts.join(', ')} of ${t.recorded}';
}

/// Days left (positive) or late (negative) for a pending observation, or
/// null when it has no target date.
int? mamrDaysLeft(Map<String, dynamic> inc, {DateTime? now}) {
  final t = DateTime.tryParse(inc['targetDate']?.toString() ?? '');
  if (t == null) return null;
  final n = now ?? DateTime.now();
  return DateTime(t.year, t.month, t.day)
      .difference(DateTime(n.year, n.month, n.day))
      .inDays;
}

String mamrDueText(int? days) {
  if (days == null) return 'No target date';
  if (days < 0) return '${-days} day${days == -1 ? '' : 's'} overdue';
  if (days == 0) return 'Due today';
  return 'Due in $days day${days == 1 ? '' : 's'}';
}

/// Background motif for MAMR surfaces: a faint plant layout plan — a survey
/// grid, bays outlined like shop zones on a site drawing, one zone hatched as
/// "your area", and a location pin on it. Purely decorative (excluded from
/// semantics) and painted, never blurred: live blur crashes mobile Safari
/// (see SafeBackdropFilter).
class MamrAreaBackdrop extends StatelessWidget {
  const MamrAreaBackdrop({super.key, required this.child, this.intensity = 1});
  final Widget child;

  /// 1 = the default faintness; lower on busy surfaces.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Stack(children: [
      Positioned.fill(
        child: ExcludeSemantics(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _PlanPainter(
                dark: sl.isDark,
                k: intensity.clamp(0.0, 1.5),
              ),
            ),
          ),
        ),
      ),
      child,
    ]);
  }
}

class _PlanPainter extends CustomPainter {
  _PlanPainter({required this.dark, required this.k});
  final bool dark;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final ink = dark ? const Color(0xFF5EEAD4) : kMamrTeal;
    Color a(double o) => ink.withOpacity((o * k).clamp(0.0, 1.0));

    // Survey grid, anchored to the right so it fades in from that side.
    final grid = Paint()
      ..color = a(dark ? 0.07 : 0.06)
      ..strokeWidth = 1;
    const step = 22.0;
    final startX = size.width * 0.35;
    for (var x = size.width; x > startX; x -= step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(startX, y), Offset(size.width, y), grid);
    }

    // Shop bays, like zones on a plant layout drawing.
    final zone = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = a(dark ? 0.20 : 0.16);
    final w = size.width, h = size.height;
    final bays = <Rect>[
      Rect.fromLTWH(w * 0.56, h * 0.08, w * 0.18, h * 0.38),
      Rect.fromLTWH(w * 0.76, h * 0.08, w * 0.20, h * 0.24),
      Rect.fromLTWH(w * 0.76, h * 0.36, w * 0.20, h * 0.30),
      Rect.fromLTWH(w * 0.56, h * 0.52, w * 0.18, h * 0.40),
      Rect.fromLTWH(w * 0.76, h * 0.70, w * 0.20, h * 0.22),
    ];
    for (final r in bays) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), zone);
    }

    // "Your area": the hatched bay.
    final mine = bays[2];
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(mine, const Radius.circular(4)));
    final hatch = Paint()
      ..color = a(dark ? 0.16 : 0.12)
      ..strokeWidth = 1.2;
    for (var d = -mine.height; d < mine.width; d += 7) {
      canvas.drawLine(Offset(mine.left + d, mine.bottom),
          Offset(mine.left + d + mine.height, mine.top), hatch);
    }
    canvas.restore();
    canvas.drawRRect(
        RRect.fromRectAndRadius(mine, const Radius.circular(4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = a(dark ? 0.38 : 0.30));

    // Walkway between the bay columns, dashed like a marked pedestrian route.
    final walk = Paint()
      ..color = a(dark ? 0.22 : 0.18)
      ..strokeWidth = 2;
    final wx = w * 0.75;
    for (var y = h * 0.06; y < h * 0.94; y += 10) {
      canvas.drawLine(Offset(wx, y), Offset(wx, y + 5), walk);
    }

    // Location pin on "your area".
    final c = Offset(mine.center.dx, mine.center.dy - 4);
    final r = (mine.shortestSide * 0.22).clamp(7.0, 16.0);
    final pin = Path()
      ..moveTo(c.dx, c.dy + r * 2.1)
      ..quadraticBezierTo(c.dx - r * 1.05, c.dy + r * 0.6, c.dx - r, c.dy)
      ..arcToPoint(Offset(c.dx + r, c.dy), radius: Radius.circular(r))
      ..quadraticBezierTo(c.dx + r * 1.05, c.dy + r * 0.6, c.dx, c.dy + r * 2.1)
      ..close();
    canvas.drawPath(pin, Paint()..color = a(dark ? 0.45 : 0.35));
    canvas.drawCircle(c, r * 0.4,
        Paint()..color = (dark ? const Color(0xFF0F172A) : Colors.white)
            .withOpacity((0.9 * k).clamp(0.0, 1.0)));
  }

  @override
  bool shouldRepaint(_PlanPainter o) => o.dark != dark || o.k != k;
}
