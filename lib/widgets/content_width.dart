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

/// Symmetric horizontal padding that centres a capped content column *inside* a
/// scroll view, without touching the widget tree.
///
/// WHY A PADDING HELPER AND NOT JUST [ContentWidth]
/// ------------------------------------------------
/// Most scroll roots in this app are `ListView(children: [...])` or
/// `SingleChildScrollView(child: Column(...))`. To apply [ContentWidth] to a
/// `ListView` you have to collapse its `children` into one wrapped `Column`,
/// which (a) rewrites dozens of widget trees by hand — every one a chance to
/// misplace a bracket in a 7,000-line file — and (b) destroys lazy building on
/// the long lists (incident log, admin tables) that need it most.
///
/// Widening the scroll view's own `padding` achieves the identical painted
/// result: the list stays full-bleed for gestures and its scrollbar keeps the
/// full track height (the two things `ContentWidth`'s doc warns you not to
/// constrain), while the content column is capped and centred. It also works
/// unchanged on `ListView.builder`, `GridView`, `CustomScrollView`
/// (`SliverPadding`) and `SingleChildScrollView` alike.
///
/// Use [ContentWidth] instead for anything that is NOT a scroll view — a
/// composer bar, a filter row, a `bottomNavigationBar`, a `TabBar` — since those
/// have no `padding` to widen.
///
/// TRAP: this reads the WINDOW width, so it is wrong inside a region that is
/// already laterally inset (e.g. the admin body, which sits beside a 240px
/// pinned drawer). Wrap those with [ContentWidth] at the inset region's root
/// instead, where the real constraints are known.
///
/// Below the cap it returns [base] unchanged, so phone layouts are untouched.
EdgeInsets slGutter(
  BuildContext context, {
  double maxWidth = SLLayout.content,
  EdgeInsets base = EdgeInsets.zero,
}) {
  final slack =
      MediaQuery.of(context).size.width - base.horizontal - maxWidth;
  if (slack <= 0) return base;
  final extra = slack / 2;
  return base.copyWith(left: base.left + extra, right: base.right + extra);
}
