import 'package:flutter/material.dart';
import '../main.dart';

// ─── LANDING INTRO (Phase 1B) ─────────────────────────────────────────────────
// What SafetyLens is, shown beside (wide) or around (narrow) the login card, so
// a first-time visitor can tell what they are signing in to.
//
// Deliberately static: no images, no fonts fetched, no animation, no network.
// The login screen must be interactive within 3 s on a fresh browser session,
// and nothing here is allowed to add to that.
//
// Colour: the icons and step markers use the brand indigo only. Red / amber /
// green are reserved for severity in this app and must not appear here.
//
// Layout: no CrossAxisAlignment.stretch on any Row — inside the login screen's
// SingleChildScrollView that silently blanks everything below it in release
// web builds.

class LandingCopy {
  LandingCopy._();

  static const String intro =
      'SafetyLens helps teams report near misses, analyse industrial safety '
      'observations with AI, identify PPE and unsafe-condition gaps from '
      'images, link findings to SOP/SMP controls, and track corrective '
      'actions to closure.';

  static const List<LandingFeature> features = [
    LandingFeature(
      icon: Icons.add_a_photo_outlined,
      title: 'Report & Capture',
      body: 'Capture a near miss, unsafe act, unsafe condition, or hazard '
          'observation with photo, location, and incident details.',
    ),
    LandingFeature(
      icon: Icons.image_search_outlined,
      title: 'AI Safety Analysis',
      body: 'Use AI-assisted image review and document evidence to identify '
          'likely hazards, PPE gaps, and control measures.',
    ),
    LandingFeature(
      icon: Icons.task_alt_outlined,
      title: 'Corrective Action Closure',
      body: 'Assign actions, track due dates, upload closure evidence, and '
          'escalate overdue safety actions.',
    ),
  ];

  static const String howItWorks = 'How it works';

  static const List<String> steps = [
    'Capture / Upload',
    'AI-assisted Review',
    'Supervisor Validation',
    'Action Assignment',
    'Closure & Analytics',
  ];
}

class LandingFeature {
  final IconData icon;
  final String title;
  final String body;
  const LandingFeature(
      {required this.icon, required this.title, required this.body});
}

/// The one-sentence product introduction.
class LandingIntroSentence extends StatelessWidget {
  /// Wide: a left-aligned lead paragraph. Narrow: a centred line under the
  /// brand, kept small so the login card stays near the top on a phone.
  final bool prominent;
  const LandingIntroSentence({super.key, this.prominent = false});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Text(
      LandingCopy.intro,
      textAlign: prominent ? TextAlign.start : TextAlign.center,
      style: TextStyle(
        color: prominent ? sl.text1 : sl.text2,
        fontSize: prominent ? 20 : 14,
        fontWeight: prominent ? FontWeight.w600 : FontWeight.w400,
        height: prominent ? 1.45 : 1.5,
      ),
    );
  }
}

/// Three feature cards followed by the five-step "How it works" flow.
class LandingDetails extends StatelessWidget {
  const LandingDetails({super.key});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < LandingCopy.features.length; i++) {
      if (i > 0) children.add(const SizedBox(height: SLSpace.sm));
      children.add(_FeatureCard(feature: LandingCopy.features[i]));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        const SizedBox(height: SLSpace.xl),
        const HowItWorks(),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final LandingFeature feature;
  const _FeatureCard({required this.feature});

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Container(
      padding: const EdgeInsets.all(SLSpace.md),
      decoration: BoxDecoration(
        color: sl.card2,
        borderRadius: SLRadius.rMd,
        border: Border.all(color: sl.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(sl.isDark ? 0.22 : 0.10),
              borderRadius: SLRadius.rSm,
            ),
            child: ExcludeSemantics(
                child: Icon(feature.icon, color: sl.accentText, size: 20)),
          ),
          const SizedBox(width: SLSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(feature.title,
                      style: TextStyle(
                          color: sl.text1,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 2),
                Text(feature.body,
                    style: TextStyle(
                        color: sl.text3,
                        fontSize: SLText.minBody,
                        height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The five steps, numbered because they genuinely are a sequence.
/// Horizontal when there is room for every label, vertical otherwise.
class HowItWorks extends StatelessWidget {
  const HowItWorks({super.key});

  /// Below this, five labels side by side would wrap to three lines each.
  static const double horizontalMinWidth = 520;

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(LandingCopy.howItWorks,
              style: TextStyle(
                  color: sl.text1, fontSize: 15, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: SLSpace.md),
        LayoutBuilder(builder: (context, c) {
          if (c.maxWidth >= horizontalMinWidth) return _horizontal(sl);
          return _vertical(sl);
        }),
      ],
    );
  }

  Widget _marker(int n) {
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
          color: AppColors.accent, shape: BoxShape.circle),
      // White on #4F5BD5 measures ~5.5:1.
      child: Text('$n',
          style: const TextStyle(
              color: Colors.white,
              fontSize: SLText.minLabel,
              fontWeight: FontWeight.w800)),
    );
  }

  Widget _line(SL sl, {required bool visible}) {
    return Container(height: 2, color: visible ? sl.border : Colors.transparent);
  }

  Widget _horizontal(SL sl) {
    final n = LandingCopy.steps.length;
    final cells = <Widget>[];
    for (var i = 0; i < n; i++) {
      cells.add(Expanded(
        child: Semantics(
          label: 'Step ${i + 1} of $n: ${LandingCopy.steps[i]}',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(child: _line(sl, visible: i > 0)),
                _marker(i + 1),
                Expanded(child: _line(sl, visible: i < n - 1)),
              ]),
              const SizedBox(height: SLSpace.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(LandingCopy.steps[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: sl.text2,
                        fontSize: SLText.minLabel,
                        fontWeight: FontWeight.w600,
                        height: 1.3)),
              ),
            ],
          ),
        ),
      ));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells);
  }

  Widget _vertical(SL sl) {
    final n = LandingCopy.steps.length;
    final rows = <Widget>[];
    for (var i = 0; i < n; i++) {
      rows.add(Semantics(
        label: 'Step ${i + 1} of $n: ${LandingCopy.steps[i]}',
        excludeSemantics: true,
        child: Row(children: [
          _marker(i + 1),
          const SizedBox(width: SLSpace.md),
          Expanded(
            child: Text(LandingCopy.steps[i],
                style: TextStyle(
                    color: sl.text2,
                    fontSize: SLText.minBody,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      ));
      if (i < n - 1) {
        // Connector centred under the 28px marker.
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 13),
          child: Container(width: 2, height: 10, color: sl.border),
        ));
      }
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: rows);
  }
}
