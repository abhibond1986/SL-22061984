// Tests for the loading skeletons.
//
// Three properties are worth protecting here, and none of them is "it looks
// right":
//
//   1. Reduced motion genuinely stops the animation. A skeleton that keeps
//      pulsing after the OS asked it not to is a WCAG 2.2 2.3.3 failure, and the
//      usual way that regresses is someone moving the MediaQuery read back into
//      initState, where the lookup silently returns the default.
//   2. The panels announce what is loading. The whole reason for replacing the
//      spinner was that it communicated nothing.
//   3. They survive a 320px-wide viewport. A layout overflow in a loading state
//      is a debug-build red stripe across the first screen a user sees.
//
// The reduced-motion test is also the one that pins the pulse down as a real
// animation: `pumpAndSettle` cannot complete while a repeating controller is
// running, so "settles under reduced motion" and "does not settle otherwise"
// together prove the switch is wired to something.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/widgets/skeleton.dart';

/// MediaQuery has to sit *inside* MaterialApp: MaterialApp installs its own
/// MediaQuery from the view, which would overwrite an ancestor one and quietly
/// turn the reduced-motion test into a no-op that always passes.
Widget _host(Widget child,
        {bool disableAnimations = false, double width = 390}) =>
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: disableAnimations),
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

/// One entry per preset, so a new preset that forgets [SkeletonPanel] or
/// overflows on a narrow phone is caught without a new test being written.
const Map<String, Widget> _presets = <String, Widget>{
  'dashboard': SkeletonDashboard(semanticLabel: 'Loading dashboard'),
  'analytics': SkeletonAnalytics(semanticLabel: 'Loading analytics'),
  'log': SkeletonLogList(semanticLabel: 'Loading records'),
  'profile': SkeletonProfile(semanticLabel: 'Loading profile'),
};

void main() {
  group('presets', () {
    _presets.forEach((name, preset) {
      testWidgets('$name draws placeholder blocks, not a spinner',
          (tester) async {
        await tester.pumpWidget(_host(preset));

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(Skeleton), findsWidgets);
      });

      testWidgets('$name lays out at 320px without overflowing',
          (tester) async {
        // 320px is the narrow end of the stated 320–1440px range. An overflow
        // throws in the test binding, so reaching the expect at all is most of
        // the assertion.
        await tester.pumpWidget(_host(preset, width: 320));
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name announces what is loading', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_host(preset));

        final label = (preset as dynamic).semanticLabel as String;
        expect(find.bySemanticsLabel(label), findsWidgets);

        handle.dispose();
      });
    });
  });

  group('reduced motion', () {
    testWidgets('settles when the platform asks for no animation',
        (tester) async {
      await tester.pumpWidget(_host(
          const SkeletonDashboard(semanticLabel: 'Loading dashboard'),
          disableAnimations: true));

      // Would time out if the controller were still repeating.
      await tester.pumpAndSettle();
      expect(find.byType(Skeleton), findsWidgets);
    });

    testWidgets('animates by default', (tester) async {
      await tester.pumpWidget(
          _host(const SkeletonDashboard(semanticLabel: 'Loading dashboard')));

      // The negative half of the pair above. If this ever stops throwing, the
      // pulse has been disconnected and the reduced-motion test is passing for
      // the wrong reason.
      bool settled = true;
      try {
        await tester.pumpAndSettle(const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
      } catch (_) {
        settled = false;
      }
      expect(settled, isFalse,
          reason: 'a repeating pulse must keep the tree unsettled');
    });

    testWidgets('still shows the layout, just without motion', (tester) async {
      await tester.pumpWidget(_host(
          const SkeletonProfile(semanticLabel: 'Loading profile'),
          disableAnimations: true));
      await tester.pumpAndSettle();

      // Degrading motion must not degrade information — the shape is the part
      // that tells the user what is coming.
      expect(find.byType(Skeleton), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('Skeleton', () {
    testWidgets('honours an explicit size', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: Skeleton(width: 120, height: 16),
      )));

      final size = tester.getSize(find.byType(Skeleton));
      expect(size.width, 120);
      expect(size.height, 16);
    });

    testWidgets('circle is square', (tester) async {
      await tester.pumpWidget(_host(const Center(
        child: Skeleton.circle(size: 48),
      )));

      final size = tester.getSize(find.byType(Skeleton));
      expect(size.width, 48);
      expect(size.height, 48);
    });

    testWidgets('works outside a panel', (tester) async {
      // A bare Skeleton must not require the inherited animation to exist —
      // otherwise dropping one into an existing card throws at runtime.
      await tester.pumpWidget(_host(const Center(child: Skeleton())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Skeleton), findsOneWidget);
    });
  });
}
