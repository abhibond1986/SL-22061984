import 'package:flutter/material.dart';
import '../main.dart';

/// One colour scheme for the bottom navigation bar, shared by the employee
/// shell (home_screen.dart) and the contractor shell
/// (contractor_home_screen.dart) so the two can never drift apart again.
///
/// 2026-10-04: the bar was a near-white indigo wash that read as "no colour".
/// It is now a solid brand-indigo band. Unselected tabs are white at 78%, and
/// the selected tab gets a white pill with an indigo icon and a bold white
/// label. Measured contrast: white on #4F5BD5 is about 5.6:1, and the indigo
/// icon on the white pill is about 5.2:1. Both clear WCAG AA.
class NavBarStyle {
  NavBarStyle._();

  static BoxDecoration decoration(SL sl) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: sl.isDark
              ? const [Color(0xFF2B3275), Color(0xFF1A1E4A)] // deep indigo
              : const [Color(0xFF5B67E0), Color(0xFF3B45B5)], // brand indigo
        ),
        // A light top hairline separates the band from page content. (No
        // shadow: the bar sits inside a ClipRRect, which would clip it.)
        border: Border(
          top: BorderSide(
              color: Colors.white.withOpacity(sl.isDark ? 0.10 : 0.25)),
        ),
      );

  /// Background of the pill behind the selected icon.
  static Color pill(SL sl, bool sel) => !sel
      ? Colors.transparent
      : sl.isDark
          ? Colors.white.withOpacity(0.92)
          : Colors.white;

  /// Icon colour: indigo when it sits on the white pill, otherwise soft white.
  static Color icon(SL sl, bool sel) => sel
      ? (sl.isDark ? const Color(0xFF2B3275) : AppColors.accent)
      : Colors.white.withOpacity(0.78);

  static Color label(SL sl, bool sel) =>
      sel ? Colors.white : Colors.white.withOpacity(0.78);
}
