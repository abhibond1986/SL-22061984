import 'package:flutter/material.dart';
import '../main.dart';
import 'safe_backdrop_filter.dart' show kLiteWebEffects;

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
          // Mobile browsers get no blur behind the bar (it crashed iPhone
          // Safari — see safe_backdrop_filter.dart), so the tint goes near
          // opaque there to keep labels off the scrolling content.
          colors: sl.isDark
              ? [
                  const Color(0xFF0C4A6E)
                      .withOpacity(kLiteWebEffects ? 0.94 : 0.45), // sky-900
                  const Color(0xFF082F49)
                      .withOpacity(kLiteWebEffects ? 0.97 : 0.60),
                ]
              : [
                  const Color(0xFFE0F2FE)
                      .withOpacity(kLiteWebEffects ? 0.95 : 0.50), // sky-100
                  const Color(0xFFBAE6FD)
                      .withOpacity(kLiteWebEffects ? 0.97 : 0.62), // sky-200
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

/// Colours for the top header (UniversalAppBar). 2026-10-04, user request:
/// "put some colour based on the app aesthetics". The header now carries the
/// brand gradient, indigo #4F5BD5 → deep teal #0E7C8A. It is the same pair the
/// avatar and logo tile already use, with the teal end darkened from #0EA5B5 so
/// white stays above 4.5:1 across the whole band. Every foreground on it is
/// white, or amber-300 for "you have unread notifications". The solid brand
/// header pairs with the light-blue glass bottom bar ([NavBarStyle]).
class TopBarStyle {
  TopBarStyle._();

  static BoxDecoration decoration(SL sl) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: sl.isDark
              ? const [Color(0xFF2A3178), Color(0xFF0B4F5A)]
              : const [Color(0xFF4F5BD5), Color(0xFF0E7C8A)],
        ),
        border: Border(
            bottom: BorderSide(color: Colors.white.withOpacity(0.12))),
      );

  static const Color fg = Colors.white;
  static Color get fgMuted => Colors.white.withOpacity(0.82);

  /// Pill/chip on the header (language toggle).
  static Color get chipFill => Colors.white.withOpacity(0.16);
  static Color get chipBorder => Colors.white.withOpacity(0.35);

  /// Bell icon when there is something unread.
  static const Color alert = Color(0xFFFCD34D); // amber-300
}
