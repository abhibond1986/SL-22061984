import 'dart:async';
import 'package:flutter/material.dart';

import '../main.dart' show SL, AppColors;
import '../services/scan_jobs.dart';

/// App-wide status surface for background photo analysis.
///
/// Mounted once, above every screen, from `MaterialApp.builder` — the app has no
/// `navigatorKey` and no global `ScaffoldMessenger` key, and the builder is the
/// one place a widget can sit over all routes without needing either.
///
/// It shows two things, and nothing else:
///
/// * a compact "analysing in background" pill while a job is in flight, so a
///   user who changed tab can see the work did not stop. Without it, moving
///   away from the scan tab looks exactly like cancelling, which is the reason
///   people used to re-scan the same hazard;
/// * a persistent failure bar with **Try again** / **Dismiss** when a job ends
///   badly, reachable from whichever screen they happen to be on.
///
/// A bar rather than a snackbar or a dialog, deliberately. A snackbar
/// auto-dismisses, and a failure a user did not happen to be looking at is a
/// failure they will act on by trusting an empty report. A dialog would seize
/// the screen — plausibly mid-sentence in the Near Miss description field. The
/// bar waits.
///
/// "Failure" here includes a *successful* HTTP round trip that produced the
/// offline fallback. That map is well-formed and carries no hazards, so on
/// screen it reads as "this scene is safe" — in a safety application that is
/// the worst possible silent outcome, and it gets the same retry offer as a
/// thrown exception.
class ScanStatusOverlay extends StatelessWidget {
  const ScanStatusOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ScanJobs.revision,
      builder: (context, _, __) {
        final failed = ScanJobs.pendingFailure;
        if (failed != null) {
          return _FailureBar(job: failed);
        }
        final job = ScanJobs.current;
        if (job != null && job.isRunning && !job.abandoned) {
          return _RunningPill(job: job);
        }
        return const SizedBox.shrink();
      },
    );
  }
}

// ─── RUNNING ──────────────────────────────────────────────────────────────────

class _RunningPill extends StatefulWidget {
  const _RunningPill({required this.job});
  final ScanJob job;
  @override
  State<_RunningPill> createState() => _RunningPillState();
}

class _RunningPillState extends State<_RunningPill> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Ticks only to refresh the elapsed-seconds label. One second, not the
    // 250ms the in-tab progress widget uses: this pill shows whole seconds, so
    // anything faster would be four rebuilds of every screen per second for no
    // visible change.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final secs = widget.job.elapsed.inSeconds;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: sl.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: sl.border),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(sl.isDark ? 0.35 : 0.10),
                      blurRadius: 10,
                      offset: const Offset(0, 3)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: sl.accentText),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    '${widget.job.kind.label} analysing…  ${secs}s',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sl.text2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── FAILED ───────────────────────────────────────────────────────────────────

class _FailureBar extends StatelessWidget {
  const _FailureBar({required this.job});
  final ScanJob job;

  /// One sentence naming what went wrong, in the user's terms.
  ///
  /// Prefers the cause [ScanJobs] recorded from an exception; otherwise the
  /// `_offline_reason` the vision chain attaches to every fallback — that field
  /// exists precisely so this kind of message can say "the daily allowance is
  /// spent" instead of always blaming the network.
  String get _headline {
    if (job.isFailed) {
      return job.errorIsNetwork
          ? 'No usable connection — ${job.kind.label.toLowerCase()} '
              'could not be analysed.'
          : '${job.kind.label} failed.';
    }
    final reason = job.offlineReason;
    return reason.isEmpty
        ? 'The AI could not analyse this photo.'
        : 'Could not analyse this photo: $reason.';
  }

  String? get _detail {
    if (job.isFailed) {
      final m = job.errorMessage ?? '';
      // The raw exception is useful to an administrator and meaningless to a
      // reporter, so it is shown only when it is not already the headline.
      return job.errorIsNetwork ? null : (m.isEmpty ? null : m);
    }
    final hint = job.offlineHint;
    return hint.isEmpty ? null : hint;
  }

  @override
  Widget build(BuildContext context) {
    final sl = SL.of(context);
    final detail = _detail;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              decoration: BoxDecoration(
                color: sl.surface,
                borderRadius: BorderRadius.circular(14),
                // A left rule rather than a red wash: the surface stays a plain
                // card so the amber/red foregrounds keep their measured
                // contrast, which a tinted fill would quietly erode.
                border: Border(
                  left: BorderSide(color: sl.redText, width: 3),
                  top: BorderSide(color: sl.border),
                  right: BorderSide(color: sl.border),
                  bottom: BorderSide(color: sl.border),
                ),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(sl.isDark ? 0.40 : 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline,
                          size: 18, color: sl.redText),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_headline,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    height: 1.3,
                                    color: sl.text1)),
                            if (detail != null) ...[
                              const SizedBox(height: 3),
                              Text(detail,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      height: 1.35,
                                      color: sl.text3)),
                            ],
                            if (job.attempts > 1) ...[
                              const SizedBox(height: 3),
                              Text('Attempt ${job.attempts} also failed.',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: sl.text4)),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: ScanJobs.dismissBanner,
                        style: TextButton.styleFrom(
                            foregroundColor: sl.text3,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 34)),
                        child: const Text('Dismiss',
                            style: TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.icon(
                        onPressed: () => ScanJobs.retry(),
                        style: FilledButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            minimumSize: const Size(0, 34),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9))),
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Try again',
                            style: TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
