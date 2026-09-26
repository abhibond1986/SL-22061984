// Loading skeletons.
//
// Replaces the full-panel `Center(child: CircularProgressIndicator())` that
// every primary screen used. A centred spinner tells the user nothing except
// "wait": it does not say what is coming, it does not reserve the layout, and
// because it looks identical on second 1 and second 12 it gives no sense of
// whether anything is still happening. The dashboard, the home tab and all four
// analytics tabs load a known shape, so drawing that shape greyed out is both
// more informative and avoids the content jumping into place on arrival.
//
// NO NEW DEPENDENCY. `shimmer` and `skeletonizer` both do this, but the app
// ships to plant Android devices under a 50 MB budget and this is forty lines of
// AnimationController.
//
// ACCESSIBILITY
//   * The sweep is suppressed when the platform asks for reduced motion
//     (WCAG 2.2 2.3.3 / 2.2.2) — an indefinitely repeating animation is exactly
//     what that setting exists to stop. The greyed layout still shows.
//   * The blocks are decorative, so the whole tree is wrapped in one
//     `Semantics(label: 'Loading …')` with `excludeSemantics`, rather than
//     letting a screen reader walk forty anonymous boxes.
//   * Greys only. Red, amber and green mean hazard severity in this app and a
//     placeholder must not appear to make a severity claim.

import 'package:flutter/material.dart';

import '../main.dart' show SL;

/// Carries the panel's shared animation down to the blocks.
///
/// Absent when the platform has asked for reduced motion, which is how a
/// [Skeleton] knows to paint itself once and stop.
class _SkeletonPulse extends InheritedWidget {
  final Animation<double> pulse;

  const _SkeletonPulse({required this.pulse, required super.child});

  static Animation<double>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_SkeletonPulse>()
      ?.pulse;

  @override
  bool updateShouldNotify(_SkeletonPulse old) => old.pulse != pulse;
}

/// A single greyed placeholder block.
class Skeleton extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const Skeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 6,
  });

  /// A circle, for avatar and icon placeholders.
  const Skeleton.circle({super.key, double size = 40})
      : width = size,
        height = size,
        radius = size / 2;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final pulse = _SkeletonPulse.maybeOf(context);

    // `t` runs 0 → 1 → 0. Only the block's own fill moves; the enclosing card
    // colours and borders are never touched, which is why this is a pulse and
    // not a ShaderMask over the whole panel.
    Widget block(double t) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            // Between the card and the border tone, so a skeleton reads as
            // "content will be here" rather than as an empty card with a
            // visible edge.
            color: Color.alphaBlend(
                sl.border.withOpacity(0.35 + 0.30 * t), sl.card),
            borderRadius: BorderRadius.circular(radius),
          ),
        );

    if (pulse == null) return block(0.5);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) => block(pulse.value),
    );
  }
}

/// Wraps a tree of [Skeleton]s and sweeps a highlight across it.
///
/// Use one of these per loading panel, not one per block: a shared controller
/// means the sweep is coherent across the whole panel and there is one ticker
/// rather than forty.
class SkeletonPanel extends StatefulWidget {
  /// Read aloud once while the panel is up. Say what is loading — "Loading
  /// dashboard" — because "Loading" alone is what the spinner already failed to
  /// communicate.
  final String semanticLabel;
  final Widget child;

  const SkeletonPanel({
    super.key,
    required this.semanticLabel,
    required this.child,
  });

  @override
  State<SkeletonPanel> createState() => _SkeletonPanelState();
}

class _SkeletonPanelState extends State<SkeletonPanel>
    with SingleTickerProviderStateMixin {
  // Slow. A fast pulse on a full-screen placeholder reads as an error state, and
  // WCAG 2.2 2.3.1 puts the flash threshold at 3Hz — this is 0.55Hz.
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  late final Animation<double> _pulse =
      _ctrl.drive(CurveTween(curve: Curves.easeInOut));

  /// Tri-state on purpose: null means "not yet decided", so the first
  /// [didChangeDependencies] always applies rather than relying on `false`
  /// happening to differ from the initial value.
  bool? _reduceMotion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read here, not in initState, because MediaQuery is an inherited lookup and
    // the user can toggle the OS setting while a slow panel is still loading.
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce == _reduceMotion) return;
    // Plain assignment, no setState: didChangeDependencies is always followed by
    // a build, so marking dirty here would be redundant at best.
    _reduceMotion = reduce;
    if (reduce) {
      _ctrl.stop();
    } else {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.semanticLabel,
      // `liveRegion` so the label is announced when the panel appears, rather
      // than only when focus happens to land on it.
      liveRegion: true,
      excludeSemantics: true,
      child: _reduceMotion == false
          ? _SkeletonPulse(pulse: _pulse, child: widget.child)
          // No inherited animation, so every block paints itself once at its
          // mid tone and never rebuilds.
          : widget.child,
    );
  }
}

/// Placeholder for one of the rounded stat/summary cards.
class SkeletonCard extends StatelessWidget {
  final double height;
  final int lines;

  const SkeletonCard({super.key, this.height = 96, this.lines = 2});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Container(
      height: height,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sl.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: sl.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < lines; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Skeleton(
              // Staggered widths. Equal-length bars read as a table rather than
              // as text that has not arrived yet.
              width: i == 0 ? 72 : 130,
              height: i == 0 ? 20 : 12,
            ),
          ],
        ],
      ),
    );
  }
}

/// Placeholder for a list of records — incidents, users, documents.
class SkeletonList extends StatelessWidget {
  final int rows;
  final bool leading;

  const SkeletonList({super.key, this.rows = 6, this.leading = true});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Column(
      children: [
        for (var i = 0; i < rows; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sl.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: sl.border),
            ),
            child: Row(
              children: [
                if (leading) ...[
                  const Skeleton.circle(size: 36),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Varying the width row to row stops the placeholder
                      // looking like a rendered table of blank cells.
                      Skeleton(height: 13, width: 120 + (i % 3) * 45),
                      const SizedBox(height: 8),
                      const Skeleton(height: 10, width: 90),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const Skeleton(width: 54, height: 22, radius: 11),
              ],
            ),
          ),
      ],
    );
  }
}

/// The dashboard / home shape: a title, a row of stat cards, then a list.
class SkeletonDashboard extends StatelessWidget {
  final String semanticLabel;
  final int statCards;
  final int rows;

  const SkeletonDashboard({
    super.key,
    this.semanticLabel = 'Loading dashboard',
    this.statCards = 4,
    this.rows = 4,
  });

  @override
  Widget build(BuildContext context) {
    return SkeletonPanel(
      semanticLabel: semanticLabel,
      child: SingleChildScrollView(
        // Never scrollable in practice, but a fixed-height skeleton overflows on
        // a 320px-wide phone in landscape, and an overflow in a loading state is
        // a red-and-yellow stripe across the screen in debug builds.
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Skeleton(width: 170, height: 22),
            const SizedBox(height: 8),
            const Skeleton(width: 110, height: 12),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, c) {
                // Two per row below 480px. Four 96px-tall cards side by side at
                // 320px leaves 60px each, which is narrower than the bars in
                // them.
                final perRow = c.maxWidth < 480 ? 2 : statCards.clamp(1, 4);
                final rowsOfCards = (statCards / perRow).ceil();
                return Column(
                  children: [
                    for (var r = 0; r < rowsOfCards; r++) ...[
                      if (r > 0) const SizedBox(height: 12),
                      Row(
                        children: [
                          for (var i = 0; i < perRow; i++) ...[
                            if (i > 0) const SizedBox(width: 12),
                            Expanded(
                              child: r * perRow + i < statCards
                                  ? const SkeletonCard()
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            const Skeleton(width: 130, height: 16),
            const SizedBox(height: 12),
            SkeletonList(rows: rows),
          ],
        ),
      ),
    );
  }
}

/// The analytics shape: a couple of filter chips, a chart block, then rows.
class SkeletonAnalytics extends StatelessWidget {
  final String semanticLabel;

  const SkeletonAnalytics({super.key, this.semanticLabel = 'Loading analytics'});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return SkeletonPanel(
      semanticLabel: semanticLabel,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Skeleton(width: 86, height: 30, radius: 15),
                SizedBox(width: 10),
                Skeleton(width: 68, height: 30, radius: 15),
                SizedBox(width: 10),
                Skeleton(width: 74, height: 30, radius: 15),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              height: 190,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: sl.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: sl.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Skeleton(width: 120, height: 14),
                  const SizedBox(height: 18),
                  // Bars of differing heights, aligned to a baseline, so the
                  // block reads as a chart rather than as a solid grey panel.
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final h in <double>[46, 78, 34, 96, 62, 84, 40])
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Skeleton(height: h, radius: 4),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const SkeletonList(rows: 3, leading: false),
          ],
        ),
      ),
    );
  }
}
