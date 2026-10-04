import 'package:flutter/material.dart';
import '../main.dart';

/// One colour scheme for the bottom navigation bar, shared by the employee
/// shell (home_screen.dart) and the contractor shell
/// (contractor_home_screen.dart) so the two can never drift apart again.
///
/// 2026-10-04 (rev 2, user request): a TRANSLUCENT light-blue "frosted glass"
/// bar. Both shells use `extendBody: true` and wrap the bar in
/// ClipRRect + BackdropFilter(blur 16), so page content scrolls visibly behind
/// it, blurred and tinted light blue.
///
/// Readability on top of moving content: the tint is 50–62% opacity (dark 45–60%)
/// and the blur flattens whatever is underneath, so the text sits on a stable
/// pale-blue field. Unselected tabs use slate #334155 (about 8:1 on the light
/// tint). The selected tab gets a white pill with a sky-700 (#0369A1) icon and
/// a sky-800 label (about 6:1). Dark mode uses a translucent navy-blue tint
/// with sky-200 text.
class NavBarStyle {
  NavBarStyle._();

  static const Color _sky700 = Color(0xFF0369A1);
  static const Color _sky800 = Color(0xFF075985);

  static BoxDecoration decoration(SL sl) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: sl.isDark
              ? [
                  const Color(0xFF0C4A6E).withOpacity(0.45), // sky-900 glass
                  const Color(0xFF082F49).withOpacity(0.60),
                ]
              : [
                  const Color(0xFFE0F2FE).withOpacity(0.50), // sky-100 glass
                  const Color(0xFFBAE6FD).withOpacity(0.62), // sky-200
                ],
        ),
        // A bright hairline on top gives the glass an edge against content.
        border: Border(
          top: BorderSide(
              color: sl.isDark
                  ? const Color(0xFF7DD3FC).withOpacity(0.25)
                  : Colors.white.withOpacity(0.9)),
        ),
      );

  /// Background of the pill behind the selected icon.
  static Color pill(SL sl, bool sel) => !sel
      ? Colors.transparent
      : sl.isDark
          ? const Color(0xFF38BDF8).withOpacity(0.28)
          : Colors.white.withOpacity(0.92);

  static Color icon(SL sl, bool sel) => sl.isDark
      ? (sel ? const Color(0xFFE0F2FE) : const Color(0xFFBAE6FD))
      : (sel ? _sky700 : const Color(0xFF334155));

  static Color label(SL sl, bool sel) => sl.isDark
      ? (sel ? Colors.white : const Color(0xFFBAE6FD))
      : (sel ? _sky800 : const Color(0xFF334155));
}
