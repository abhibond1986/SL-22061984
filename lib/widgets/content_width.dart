import 'package:flutter/material.dart';
import '../main.dart' show SLLayout;

/// Centres its child and caps how wide it may grow.
///
/// WHY THIS EXISTS
/// ---------------
/// The app has no responsive layer. The whole-app UI audit found exactly one
/// breakpoint in the entire codebase (the admin drawer at 900px) and no maximum
/// content width anywhere, so the web build is a phone layout stretched edge to
/// edge across a 1920px browser. On the AI Hazard Scan that is not merely ugly —
/// it is the single loudest "unfinished" signal on the page:
///
///   * the Likelihood and Severity dropdowns become ~500px wide each to hold the
///     words "3 · Possible", so the two controls that matter read as form
///     scaffolding rather than as a rating;
///   * the 5×5 risk matrix (73px of grid) is marooned in whitespace beside a
///     19pt band word, breaking the "instrument + its reading" pairing the matrix
///     card is built around;
///   * body copy runs to 130+ characters per line, well past the ~75 that is
///     comfortable to read.
///
/// The width tokens themselves already existed in `SLLayout` — they were simply
/// never used. This widget is the missing call site, not a new scale.
///
/// Placement matters: wrap the *content* of a scroll view, not the scroll view
/// itself. Constraining the scrollable would shorten the scrollbar's track and,
/// on a `SingleChildScrollView`, move the touch-to-scroll region away from the
/// window edges. Wrapping the child keeps the gesture area full-bleed and only
/// narrows the painted column.
///
/// Below the cap this widget is a no-op, so phone layouts are untouched.
class ContentWidth extends StatelessWidget {
  const ContentWidth({
    super.key,
    required this.child,
    this.maxWidth = SLLayout.content,
  });

  /// Reading column for task screens. Use [SLLayout.wide] for tables and
  /// analytics, [SLLayout.form] for single-column entry.
  final double maxWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}
