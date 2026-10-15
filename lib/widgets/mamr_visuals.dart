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
