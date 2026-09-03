// lib/widgets/analysis_progress.dart
//
// The bar shown while a photo is being analysed, on the AI Hazard Scan tab and
// on the Near Miss tab.
//
// WHAT THIS IS HONEST ABOUT, AND WHAT IT IS NOT
//
// The bar is TIME-BASED. The vision chain is one opaque await — GeminiVision
// exposes no progress callback, and no provider in the chain reports how far
// through a request it is — so there is no measured fraction to display. What we
// do have is a measured *shape*: gemini_vision.dart records a real web scan at
// 56,950ms total, with a 20s per-attempt ceiling (kAttemptTimeout) and a 40s
// ceiling on the whole free OpenRouter tier (_kOrChainBudget). Those numbers are
// the tier boundaries this widget animates against, so the phase captions track
// what is actually happening in the chain rather than being decorative.
//
// THE SHAPE MOVED ON 2026-09-03 and this widget has not been re-measured. Direct
// Gemini was promoted ahead of the free OpenRouter models, and its measured leg
// is ~7s, so a scan on a device with a Gemini key should now finish well inside
// the 22s `expected` default. That makes the bar PESSIMISTIC, not wrong: it
// under-reports progress and finishes early, which is the safe direction and
// still obeys rule 1 below. Do not retune `expected` downward until there are
// real timings from the new order — a bar tuned to 8s that then waits out a
// 40s OpenRouter fallback breaks rule 2, which is the more damaging failure.
//
// Because it is a prediction, two rules apply and must not be relaxed:
//
//   1. IT NEVER REACHES 100%. It approaches a ceiling asymptotically. A bar that
//      fills and then sits there for twenty seconds is worse than no bar — it
//      says the work is finished when it is not, and the user starts tapping.
//
//   2. WHEN IT OVERRUNS, IT SAYS SO. Past the expected duration the caption
//      changes to admit the wait is longer than usual instead of continuing to
//      imply everything is on schedule. An honest "this is slow" keeps a user
//      waiting; a bar that lies gets the app closed and the hazard unreported.
//
// The elapsed seconds are real, and are the thing to trust on screen.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

class AnalysisProgress extends StatefulWidget {
  const AnalysisProgress({
    super.key,
    required this.accent,
    this.expected = const Duration(seconds: 22),
    this.title = 'Analysing the photo',
    this.compact = false,
  });

  /// Brand colour for the bar. Passed in rather than read from the theme so the
  /// widget works unchanged over a darkened photo, which is where both callers
  /// put it.
  final Color accent;

  /// How long a normal run takes. 22s by default: the 2026-08-17 measurement had
  /// the model that actually answered returning in ~11s, and the chain adds the
  /// rate-limit sleep, the key sync and the knowledge-base fetch on top.
  final Duration expected;

  final String title;

  /// Drops the title line — for the smaller Near Miss overlay, which is 140px
  /// tall and has its own heading above.
  final bool compact;

  @override
  State<AnalysisProgress> createState() => _AnalysisProgressState();
}

class _AnalysisProgressState extends State<AnalysisProgress> {
  final _sw = Stopwatch();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _sw.start();
    // 250ms, not 1s: the bar has to visibly move between caption changes or it
    // reads as frozen, which is the whole complaint this widget answers.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Fraction, asymptotic to 0.97 — see rule 1 in the header.
  ///
  /// 1 - e^(-3t/expected) puts it near 0.80 at the expected time and then slows
  /// sharply, so an overrun keeps creeping instead of stopping dead, and the
  /// remaining 20% is available to represent a genuinely slow run rather than
  /// having been spent early to look busy.
  double get _fraction {
    // Guard the divisor. A caller passing Duration.zero would produce 0/0 = NaN,
    // and a NaN `value` trips an assert inside LinearProgressIndicator in debug
    // and paints nothing in release.
    final ms = widget.expected.inMilliseconds;
    if (ms <= 0) return 0.5;
    final t = _sw.elapsedMilliseconds / ms;
    return (1 - math.exp(-3 * t)) * 0.97;
  }

  /// What the chain is most likely doing, from the tier boundaries in
  /// gemini_vision.dart. Thresholds are absolute seconds, not fractions of
  /// [expected], because the tier timeouts they mirror are absolute too.
  String get _phase {
    final s = _sw.elapsed.inSeconds;
    if (s < 3) return 'Preparing the photo…';
    if (s < 8) return 'Sending it to the AI reader…';
    if (s < 20) return 'Looking for hazards in the scene…';
    if (s < 40) {
      return 'The first model is slow — trying another. Nothing has stalled.';
    }
    if (s < 70) return 'Falling back to the backup model…';
    return 'Still working. Free AI services queue requests when busy.';
  }

  @override
  Widget build(BuildContext context) {
    final s = _sw.elapsed.inSeconds;
    final over = _sw.elapsed > widget.expected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.compact) ...[
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _fraction,
              minHeight: 6,
              backgroundColor: Colors.white.withOpacity(0.18),
              valueColor: AlwaysStoppedAnimation<Color>(widget.accent),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _phase,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white.withOpacity(0.92),
                fontSize: 11,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            // Rule 2: past the expected duration, admit it.
            over
                ? '${s}s — longer than usual, still going'
                : '${s}s of about ${widget.expected.inSeconds}s',
            style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 10,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
