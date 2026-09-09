import 'dart:async';
import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'ai_run_log.dart';
import 'gemini_vision.dart';
import 'geo_service.dart';

/// Which screen asked for the analysis.
///
/// Carried on the job rather than inferred, for two reasons: it selects the
/// `runType` the telemetry inside [GeminiVision] attributes the run to, and it
/// is what lets a screen decide whether a finished job on the service is *its*
/// job. The AI Scan tab must never adopt a near-miss result and vice versa.
enum ScanJobKind { hazardScan, nearMissImage }

extension ScanJobKindX on ScanJobKind {
  /// The telemetry run type for this kind. Kept here so the mapping lives in
  /// one place instead of being repeated at each call site.
  String get runType => this == ScanJobKind.nearMissImage
      ? AiRunLog.typeNearMissImage
      : AiRunLog.typeHazardScan;

  /// Human label for banners and blocked-start messages.
  String get label =>
      this == ScanJobKind.nearMissImage ? 'Near miss photo' : 'Hazard scan';
}

enum ScanJobStatus { running, done, failed }

/// One photo analysis, owned by [ScanJobs] rather than by a widget.
///
/// Everything needed to (a) rebuild the waiting UI from scratch, (b) hand the
/// finished result to whichever screen owns it, and (c) re-run the exact same
/// call on retry, lives on this object. That is the whole point: the screen
/// that started the job is disposed the moment the user changes tab, so
/// nothing that matters may live only in its `State`.
class ScanJob {
  ScanJob({
    required this.id,
    required this.kind,
    required this.bytes,
    required this.filePath,
    required this.plant,
    required this.dept,
    required this.sceneContext,
    required this.forceRefresh,
    this.pickedFile,
    this.location,
    this.previousResult,
    this.attempts = 1,
    Uint8List? previewBytes,
  })  : previewBytes = previewBytes ?? bytes,
        startedAt = DateTime.now();

  final String id;
  final ScanJobKind kind;

  /// The exact bytes the analysis was sent.
  ///
  /// Held separately from [previewBytes] because the GPS watermark is applied
  /// to the displayed image *after* the analysis starts, and the consistency
  /// cache in [GeminiVision] keys on a content hash of what was actually sent.
  /// Retrying with the watermarked bytes would file the answer under a
  /// different key than the one the first attempt rejected.
  final Uint8List bytes;

  /// Path of the picked file, used by the non-web branch which re-reads from
  /// disk. Null on web.
  final String? filePath;

  /// Kept so the owning screen can restore its save/upload flow after adopting
  /// a job it did not start in this widget lifetime.
  final XFile? pickedFile;

  final String plant;
  final String dept;
  final String sceneContext;
  final bool forceRefresh;
  final DateTime startedAt;

  /// The image as it should be SHOWN — i.e. watermarked once GPS lands.
  /// Mutable, because the watermark arrives mid-flight.
  Uint8List previewBytes;

  /// GPS captured alongside the analysis. Lives here so a tab switch does not
  /// orphan the location capture either; it was previously held only in the
  /// scan tab's `State` and lost on exactly the same navigation.
  LocationData? location;

  /// The report that was already on screen when a re-analysis was requested.
  ///
  /// Carried on the job because the guard that protects it ("a failed
  /// re-analysis must not delete the report it was asked to double-check") used
  /// to read the widget's own `_result` — which is null in the fresh `State`
  /// created by a tab switch. Since switching tabs mid-scan is now the normal
  /// case rather than an accident, that guard would have failed exactly when it
  /// was most needed.
  final Map<String, dynamic>? previousResult;

  ScanJobStatus status = ScanJobStatus.running;

  /// Caption for the progress overlay. Empty means "let [AnalysisProgress] use
  /// its own honest heading" — see the note in near_miss_tab.
  String step = '';

  Map<String, dynamic>? result;

  /// User-facing failure text. Never a raw Dart exception on its own.
  String? errorMessage;
  Object? error;
  StackTrace? stackTrace;
  bool errorIsNetwork = false;

  /// How many times this photo has been attempted, for the banner's wording, so
  /// a permanently-failing photo does not read as a fresh failure each time.
  final int attempts;

  /// Set when the user dismissed the failure banner. The job stays on the
  /// service (the owning screen may still want to show its own state) but the
  /// app-wide banner stops offering it.
  bool bannerDismissed = false;

  /// Set when a result is no longer wanted — the user reset the screen or
  /// picked a different photo. An abandoned job's completion is dropped.
  bool abandoned = false;

  bool get isRunning => status == ScanJobStatus.running;
  bool get isFailed => status == ScanJobStatus.failed;
  bool get isDone => status == ScanJobStatus.done;

  Duration get elapsed => DateTime.now().difference(startedAt);

  /// True when the chain returned but the answer is not a real analysis — the
  /// offline fallback. Treated as a failure by the banner, because a report
  /// reading "no hazards found" for a provider outage is the single most
  /// dangerous output this app can produce, and the user must be given the
  /// chance to try again rather than left to trust it.
  bool get resultIsOffline =>
      result != null &&
      (result!['_isOnline'] != true || result!['_imageAnalysed'] == false);

  String get offlineReason => result?['_offline_reason']?.toString() ?? '';
  String get offlineHint => result?['_offline_hint']?.toString() ?? '';
}

/// Runs photo hazard analysis independently of any widget.
///
/// **The problem this solves.** The AI Scan tab and the Near Miss tab both used
/// to `await GeminiVision` from inside their own `State`, and the app shell
/// (`home_screen.dart`) swaps tabs through an `AnimatedSwitcher`, which
/// *disposes* the outgoing tab. The HTTP request itself kept running — nothing
/// in the chain is cancellable, `http.post` has no abort — but every
/// continuation after the await is gated on `if (mounted)`, so a 30-second
/// analysis that a user navigated away from completed, wrote its telemetry and
/// its cache entry, and then threw the answer away in silence. The user came
/// back to an empty "not analysed" screen with no error and no explanation, and
/// the natural response is to scan the same hazard again.
///
/// **Shape of the fix.** The future is owned here and never awaited by a
/// widget. Screens observe [revision] and read [current]; they may come and go
/// freely. This mirrors the codebase's established convention — an all-static
/// service plus a `ValueNotifier` others listen to, as in `AdminMasterData
/// .revision`, `RealtimeSync.incidentsRevision` and
/// `SopScanScreen.hasUnsavedWork`.
///
/// **Why only one job at a time.** [GeminiVision] holds a process-wide
/// `_isAnalyzing` mutex with a 30-second wait loop, after which a second
/// concurrent call degrades to the offline fallback and is logged as
/// `reasonConcurrent`. In a safety application that fallback reports "no
/// hazards", so allowing a second scan to start would not merely be wasteful,
/// it would manufacture a clean bill of health for an unexamined photo.
/// [start] therefore refuses while a job is in flight and the caller is told
/// why. There is deliberately no "cancel and start now" — it could not be
/// honoured, since the in-flight request cannot be aborted and the mutex would
/// not clear.
class ScanJobs {
  ScanJobs._();

  /// Bumped on every observable change to [current]. Widgets rebuild from it.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static ScanJob? _current;
  static ScanJob? get current => _current;

  static bool get isRunning => _current?.isRunning == true;

  /// A job whose failure the app-wide banner should be offering right now.
  ///
  /// Counts both a thrown error and a completed-but-offline result, since to
  /// the user those are the same event: no analysis happened.
  static ScanJob? get pendingFailure {
    final j = _current;
    if (j == null || j.abandoned || j.bannerDismissed) return null;
    if (j.isFailed) return j;
    if (j.isDone && j.resultIsOffline) return j;
    return null;
  }

  static int _seq = 0;

  static void _notify() => revision.value++;

  /// Starts an analysis, or returns null if one is already running.
  ///
  /// A null return is not an error condition to swallow — the caller should
  /// tell the user, and [busyMessage] supplies the wording.
  /// [previewBytes] and [location] must be passed to the constructor rather than
  /// assigned after the fact: [_notify] fires before this method returns, so a
  /// listening screen mirrors the job's fields synchronously. Setting them
  /// afterwards was too late — the scan tab had already replaced the
  /// GPS-watermarked photo on screen with the raw analysis bytes, and that
  /// watermarked image is what gets saved and exported.
  static ScanJob? start({
    required ScanJobKind kind,
    required Uint8List bytes,
    String? filePath,
    XFile? pickedFile,
    String plant = '',
    String dept = '',
    String sceneContext = '',
    bool forceRefresh = false,
    Uint8List? previewBytes,
    LocationData? location,
    Map<String, dynamic>? previousResult,
    int attempts = 1,
  }) {
    if (isRunning) return null;

    // A new photo supersedes any finished job, including a failed one. Its
    // banner goes with it, or the user gets a retry offer for a photo that is
    // no longer on screen.
    final job = ScanJob(
      id: 'scan-${++_seq}-${DateTime.now().millisecondsSinceEpoch}',
      kind: kind,
      bytes: bytes,
      filePath: filePath,
      pickedFile: pickedFile,
      plant: plant,
      dept: dept,
      sceneContext: sceneContext,
      forceRefresh: forceRefresh,
      previewBytes: previewBytes,
      location: location,
      previousResult: previousResult,
      attempts: attempts,
    );
    _current = job;
    _notify();
    // Deliberately not awaited: this is the entire point of the service.
    _run(job);
    return job;
  }

  /// Why a [start] returned null, phrased for a user rather than a log.
  static String busyMessage() {
    final j = _current;
    if (j == null) return 'An analysis is already running.';
    final secs = j.elapsed.inSeconds;
    return '${j.kind.label} is still being analysed (${secs}s). '
        'It keeps running in the background — you will be told when it '
        'finishes. Please wait for it before starting another.';
  }

  static Future<void> _run(ScanJob job) async {
    try {
      final Map<String, dynamic>? result = kIsWeb || job.filePath == null
          ? await GeminiVision.analyseImageBytes(
              job.bytes,
              runType: job.kind.runType,
              plant: job.plant,
              dept: job.dept,
              sceneContext: job.sceneContext,
              forceRefresh: job.forceRefresh,
            )
          : await GeminiVision.analyseImage(
              File(job.filePath!),
              runType: job.kind.runType,
              plant: job.plant,
              dept: job.dept,
              sceneContext: job.sceneContext,
              forceRefresh: job.forceRefresh,
            );

      // A superseded job must not write anything back, or a stale answer lands
      // on the photo the user replaced it with.
      if (_current != job) return;
      job.result = result;
      job.status = ScanJobStatus.done;
      job.step = '';
      _notify();
    } catch (e, st) {
      if (_current != job) return;
      final s = e.toString().toLowerCase();
      job.errorIsNetwork = s.contains('socket') ||
          s.contains('network') ||
          s.contains('connection') ||
          s.contains('timeout') ||
          s.contains('failed host lookup');
      job.error = e;
      job.stackTrace = st;
      job.errorMessage = job.errorIsNetwork
          ? 'Poor internet connectivity — the photo could not be analysed.'
          : 'Analysis failed: $e';
      job.status = ScanJobStatus.failed;
      job.step = '';
      _notify();
    }
  }

  /// Re-runs the current job's analysis with identical inputs.
  ///
  /// [forceRefresh] is forced on: the user is retrying precisely because the
  /// last answer was unusable, and the consistency cache would otherwise be
  /// entitled to hand back a stored result for the same image hash. Returns
  /// the new job, or null if something is already running.
  static ScanJob? retry() {
    final old = _current;
    if (old == null || old.isRunning) return null;
    return start(
      kind: old.kind,
      bytes: old.bytes,
      filePath: old.filePath,
      pickedFile: old.pickedFile,
      plant: old.plant,
      dept: old.dept,
      sceneContext: old.sceneContext,
      forceRefresh: true,
      // Carried into the constructor, not assigned afterwards: a screen mirrors
      // the new job synchronously inside start(), so a late write would arrive
      // after the watermarked photo had already been replaced on screen.
      previewBytes: old.previewBytes,
      location: old.location,
      previousResult: old.previousResult,
      attempts: old.attempts + 1,
    );
  }

  /// Hides the app-wide failure banner without discarding the job.
  static void dismissBanner() {
    final j = _current;
    if (j == null) return;
    j.bannerDismissed = true;
    _notify();
  }

  /// Updates the image to display — used when the GPS watermark lands.
  ///
  /// [jobId] identifies which analysis the caller believes it is updating, and
  /// the write is dropped unless that is still the current one. The GPS capture
  /// it serves can take tens of seconds and is not cancellable, so it routinely
  /// outlives the scan that started it; without this check a late watermark
  /// could be stamped onto the next photo the user picked, or onto a near-miss
  /// job started from the other tab.
  static void updatePreview(String? jobId, Uint8List bytes) {
    final j = _current;
    if (j == null || jobId == null || j.id != jobId) return;
    j.previewBytes = bytes;
    _notify();
  }

  /// See [updatePreview] for why this is keyed to a specific job.
  static void updateLocation(String? jobId, LocationData? loc) {
    final j = _current;
    if (j == null || jobId == null || j.id != jobId) return;
    j.location = loc;
    _notify();
  }

  static void updateStep(String? jobId, String step) {
    final j = _current;
    if (j == null || jobId == null || j.id != jobId || !j.isRunning) return;
    j.step = step;
    _notify();
  }

  /// Drops the job entirely — the screen was reset or the report was saved.
  ///
  /// A running job is marked abandoned rather than cleared, because its future
  /// is still in flight and still holds [GeminiVision]'s mutex; clearing
  /// [_current] would let a second scan start into that mutex and degrade to
  /// the offline "no hazards" fallback.
  static void clear() {
    final j = _current;
    if (j == null) return;
    if (j.isRunning) {
      j.abandoned = true;
      j.bannerDismissed = true;
    } else {
      _current = null;
    }
    _notify();
  }

  /// The job a screen of [kind] may adopt.
  ///
  /// Deliberately still returns a *finished* job. A screen re-entered after a
  /// tab switch has a brand-new `State` with nothing in it, and re-applying the
  /// stored result is exactly how the report reappears instead of the user
  /// landing on an empty "not analysed" screen. The owning screen tracks which
  /// job id it has already applied so it does not do so twice in one lifetime.
  static ScanJob? adoptable(ScanJobKind kind) {
    final j = _current;
    if (j == null || j.abandoned || j.kind != kind) return null;
    return j;
  }
}
