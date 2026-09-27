// Tests for the login-screen product introduction (Phase 1B).
//
// What is worth protecting:
//   1. The brief's exact copy is present — the three card titles, the intro
//      sentence and all five steps, in order.
//   2. It lays out without overflow across the stated 320–1440px range, in
//      both the vertical (narrow) and horizontal (wide) step layouts.
//   3. Screen readers get headings and "Step n of 5" labels.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safety_lens/widgets/landing_intro.dart';

Widget _host(double width, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: SingleChildScrollView(
          // Align loosens the Scaffold's constraints so the SizedBox width
          // is the width the widgets actually get.
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LandingIntroSentence(),
                  LandingIntroSentence(prominent: true),
                  LandingDetails(),
                ],
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('shows the intro sentence, three cards and five steps',
      (tester) async {
    await tester.pumpWidget(_host(600));

    expect(find.text(LandingCopy.intro), findsNWidgets(2));
    expect(find.text('Report & Capture'), findsOneWidget);
    expect(find.text('AI Safety Analysis'), findsOneWidget);
    expect(find.text('Corrective Action Closure'), findsOneWidget);
    expect(find.text('How it works'), findsOneWidget);
    expect(LandingCopy.steps, const [
      'Capture / Upload',
      'AI-assisted Review',
      'Supervisor Validation',
      'Action Assignment',
      'Closure & Analytics',
    ]);
  });

  for (final width in const [320.0, 390.0, 519.0, 520.0, 612.0, 1440.0]) {
    for (final b in Brightness.values) {
      testWidgets('lays out at ${width.toInt()}px ($b) without overflow',
          (tester) async {
        // The default 800px test view would silently clamp 1440 to 800.
        tester.view.physicalSize = const Size(1600, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_host(width, brightness: b));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('steps are announced in order with their position',
      (tester) async {
    for (final width in const [320.0, 1000.0]) {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(width));
      for (var i = 0; i < LandingCopy.steps.length; i++) {
        expect(
            find.bySemanticsLabel(
                'Step ${i + 1} of 5: ${LandingCopy.steps[i]}'),
            findsOneWidget);
      }
      handle.dispose();
    }
  });
}
