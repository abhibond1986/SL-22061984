// A persistent notice that some part of startup did not complete.
//
// StartupDiagnostics has always collected this — `degradedSteps` and
// `hadFailures` existed and were tested — but nothing in lib/ ever read them, so
// a user whose local database or locale failed to initialise got a working-looking
// app that quietly could not save. The whole point of degrading instead of
// hanging is that the user finds out.
//
// COLOUR: slate, not amber. Red, amber and green are reserved for hazard
// severity across this app and match plant signage; borrowing amber for a
// system-status message would mean the same colour said "MEDIUM risk" in one
// place and "app is degraded" in another. Slate is the established
// no-claim-made neutral. Colour is never the only signal either — there is an
// icon and a sentence, per WCAG 2.2 1.4.1.

import 'package:flutter/material.dart';

import '../services/startup_diagnostics.dart';

class LimitedModeBanner extends StatefulWidget {
  const LimitedModeBanner({super.key});

  @override
  State<LimitedModeBanner> createState() => _LimitedModeBannerState();
}

class _LimitedModeBannerState extends State<LimitedModeBanner> {
  // Read once. Every guarded startup step has already run and been recorded by
  // the time `runApp` is called, so this list cannot change underneath us — and
  // re-reading a static on every rebuild would make the banner flicker if a
  // later phase ever does add a guarded step.
  late final List<String> _failed = StartupDiagnostics.degradedSteps;

  bool _dismissed = false;
  bool _expanded = false;

  /// Slate — the app's "no safety claim is being made" neutral.
  static const Color _fill = Color(0xFF475569);

  /// Minimum interactive size. WCAG 2.2 AA asks for 24×24; the project target is
  /// 44×44 because this is used in gloves on a plant floor.
  static const double _tapTarget = 44;

  @override
  Widget build(BuildContext context) {
    if (_failed.isEmpty || _dismissed) return const SizedBox.shrink();

    return SafeArea(
      // Only the top inset matters; taking the others would push the banner off
      // a notched phone's left edge in landscape for no reason.
      left: false,
      right: false,
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          color: _fill,
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.cloud_off_outlined,
                        color: Colors.white, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _summary,
                          // White on slate is 7.4:1 — measured by hand, because
                          // the contrast audit script only scores tokens against
                          // the two global backgrounds and cannot see this fill.
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                    _IconAction(
                      tooltip: _expanded ? 'Hide details' : 'Show details',
                      icon: _expanded ? Icons.expand_less : Icons.expand_more,
                      size: _tapTarget,
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                    _IconAction(
                      tooltip: 'Dismiss',
                      icon: Icons.close,
                      size: _tapTarget,
                      onPressed: () => setState(() => _dismissed = true),
                    ),
                  ],
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(left: 30, bottom: 4, right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final name in _failed)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text('• $name did not start',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          'Restarting the app usually clears this. '
                          'If it keeps happening, quote reference '
                          '${StartupDiagnostics.sessionReference} to support.',
                          style: TextStyle(
                            // Slightly dimmed, still above 4.5:1 on slate.
                            color: Colors.white.withOpacity(0.85),
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _summary {
    // Naming the affected feature beats a count: "Local database did not start"
    // tells the user their reports may not save, which is the decision they
    // actually have to make.
    if (_failed.length == 1) {
      return 'Running in limited mode — ${_failed.first} did not start.';
    }
    return 'Running in limited mode — ${_failed.length} features did not start.';
  }
}

/// An icon button with a guaranteed minimum tap target.
///
/// `IconButton`'s own default is 48 but shrinks with `visualDensity` and the
/// ambient theme, so the size is pinned here rather than inherited.
class _IconAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final double size;
  final VoidCallback onPressed;

  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Center(
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}
