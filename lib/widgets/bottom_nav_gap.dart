import 'package:flutter/material.dart';

/// Vertical space that reserves room for the frosted bottom navigation bar.
///
/// WHY THIS EXISTS
/// ---------------
/// Both app shells (`HomeScreen` and `ContractorHomeScreen`) build their
/// `Scaffold` with `extendBody: true` so that scrolling content passes *behind*
/// the translucent, blurred nav bar — that is the whole point of the frosted
/// look. The cost is that the bar does **not** inset the body, so the last row
/// of any scroll view ends up underneath it and is unreadable. On the Home tab
/// this clipped the final "Recent Activity" entry; the same class of bug exists
/// in every tab that scrolls to its end.
///
/// A fixed `SizedBox(height: 24)` is not enough and a hardcoded `84` breaks on
/// devices with a gesture bar, so the gap is measured: the bar is a 60px row
/// wrapped in a `SafeArea`, therefore its true occupied height is
/// `60 + viewPadding.bottom`. `viewPadding` (not `padding`) is deliberate — it
/// keeps reporting the physical inset even when a `SafeArea` above us has
/// already consumed it, which is exactly the situation inside a tab body.
///
/// Use as the final child of a tab's scrolling `Column`/`ListView`, replacing
/// any trailing spacer.
class BottomNavGap extends StatelessWidget {
  const BottomNavGap({super.key, this.extra = 16});

  /// Breathing room *above* the nav bar, so the last card does not sit flush
  /// against the bar's hairline border.
  final double extra;

  /// Height of the nav bar itself. Exposed so callers that need the value as
  /// padding (e.g. `ListView(padding: ...)`) can reuse the same measurement
  /// instead of guessing.
  static double height(BuildContext context) =>
      60 + MediaQuery.of(context).viewPadding.bottom;

  /// Ready-made bottom inset for a scroll view's `padding`.
  static EdgeInsets padding(BuildContext context, {double extra = 16}) =>
      EdgeInsets.only(bottom: height(context) + extra);

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height(context) + extra);
}
