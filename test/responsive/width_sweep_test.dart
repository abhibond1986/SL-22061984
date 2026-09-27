// Screen-width sweep.
//
// Opens every main screen at each width in [sweepWidths] (320px phone up to a
// 1920px desktop), in light and dark mode, and fails if Flutter reports a
// layout overflow ("A RenderFlex overflowed by N pixels") or an unbounded
// constraint. Those are the errors that show on a device as a yellow-and-black
// stripe, or as content cut off at the edge of the screen.
//
// The test does not compare screenshots. Pixel goldens break on any
// intentional restyle and differ between machines. An overflow is a
// structural fact, the same everywhere, so it makes a stable CI gate.
//
// When this fails, the message names the width, theme, screen and the widget
// that overflowed. Reproduce it by running only that case:
//   flutter test test/responsive/width_sweep_test.dart --plain-name "360"

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/screens/admin_screen.dart';
import 'package:safety_lens/screens/contractor_home_screen.dart';
import 'package:safety_lens/screens/home_screen.dart';
import 'package:safety_lens/screens/login_screen.dart';

import 'harness.dart';

/// Employee shell tabs, by the label shown in the bottom bar or side rail. The
/// admin account is used so that every tab (including SOP) is visible.
const _homeTabs = ['Home', 'AI Scan', 'Near Miss', 'SOP', 'Ask AI', 'Reports'];

/// Contractor shell tabs.
const _contractorTabs = ['AI Scan', 'Near Miss'];

Future<void> _sweep(
  WidgetTester tester, {
  required double width,
  required Brightness brightness,
  required Widget Function() screen,
  List<String> tabs = const [],
  String name = '',
  bool admin = true,
}) async {
  await loadRealFonts();
  await seedSignedInUser(admin: admin);
  setWindow(tester, width, height: 900);
  final errs = LayoutErrors()..start();
  final problems = <String>[];
  try {
    await tester.pumpWidget(appHost(screen(), brightness: brightness));
    await pumpFrames(tester, frames: 12);
    void collect(String where) {
      for (final o in errs.overflows) {
        problems.add('$where: $o');
      }
      errs.overflows.clear();
    }

    collect(tabs.isEmpty ? name : tabs.first);
    for (final t in tabs.skip(1)) {
      final f = find.text(t);
      if (f.evaluate().isEmpty) {
        problems.add('$t: tab label not found, so the tab was not checked');
        continue;
      }
      await tester.tap(f.last, warnIfMissed: false);
      await pumpFrames(tester, frames: 12);
      collect(t);
    }
  } finally {
    errs.stop();
  }
  await drainTimers(tester);
  final mode = brightness == Brightness.dark ? 'dark' : 'light';
  expect(problems, isEmpty,
      reason: 'Layout problems at ${width.toInt()}px ($mode):\n  '
          '${problems.join('\n  ')}');
}

void main() {
  for (final brightness in const [Brightness.light, Brightness.dark]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    for (final w in sweepWidths) {
      final px = '${w.toInt()}px $mode';

      testWidgets('employee shell, every tab @ $px', (tester) async {
        await _sweep(tester,
            width: w,
            brightness: brightness,
            tabs: _homeTabs,
            screen: () => HomeScreen(toggleTheme: () {}));
      });

      testWidgets('contractor shell @ $px', (tester) async {
        await _sweep(tester,
            width: w,
            brightness: brightness,
            tabs: _contractorTabs,
            admin: false,
            screen: () => ContractorHomeScreen(toggleTheme: () {}));
      });

      testWidgets('login screen @ $px', (tester) async {
        await _sweep(tester,
            width: w,
            brightness: brightness,
            name: 'Login',
            screen: () => LoginScreen(toggleTheme: () {}));
      });

      testWidgets('admin screen @ $px', (tester) async {
        await _sweep(tester,
            width: w,
            brightness: brightness,
            name: 'Admin',
            screen: () => const AdminScreen());
      });
    }
  }
}
