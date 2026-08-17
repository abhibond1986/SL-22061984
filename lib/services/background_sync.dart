// lib/services/background_sync.dart
// ★ v25: Periodic background sync — retries pending items every 5 minutes.
// ★ FIX: Also pulls master data so admin changes reach users even without navigation.
// Runs while the app is open. Stops on dispose.

import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'sync_service.dart';
import 'app_logger.dart';
import 'ai_run_log.dart';
import 'admin_master_data.dart';

class BackgroundSync {
  static Timer? _timer;
  static bool _running = false;

  /// How often to retry pending sync items (in minutes)
  static const int _intervalMinutes = 5;

  /// Start the periodic sync timer
  static void start() {
    if (_timer != null) return; // Already running
    _timer = Timer.periodic(
      Duration(minutes: _intervalMinutes),
      (_) => _runSync(),
    );
    debugPrint('[BackgroundSync] Started — retrying every $_intervalMinutes minutes');
  }

  /// Stop the periodic timer
  static void stop() {
    _timer?.cancel();
    _timer = null;
    debugPrint('[BackgroundSync] Stopped');
  }

  /// Run a sync cycle
  static Future<void> _runSync() async {
    if (_running) return; // Prevent overlapping runs
    _running = true;

    try {
      // AI telemetry backlog first, and BEFORE the early return below: it has
      // its own queue, so a cycle where the incident queue is empty must still
      // retry stranded runs. Cheap no-op when nothing is pending.
      await AiRunLog.flushUnsynced().catchError((_) => 0);

      // ★ FIX: Always pull master data so admin changes reach users
      // even when the pending queue is empty. This covers the gap where
      // users are parked on non-Home screens and fullSync never runs.
      try {
        await AdminMasterData.syncFromBackend();
      } catch (_) {}

      final pending = await SyncService.getPendingCount();
      if (pending == 0) {
        return; // Nothing else to sync
      }

      debugPrint('[BackgroundSync] Retrying $pending pending items...');
      AppLogger.info('BackgroundSync', 'Retrying $pending pending items');

      final synced = await SyncService.drainPendingQueue();
      if (synced > 0) {
        debugPrint('[BackgroundSync] Successfully synced $synced items');
        AppLogger.info('BackgroundSync', 'Synced $synced items');
      }

      final remaining = await SyncService.getPendingCount();
      if (remaining > 0) {
        AppLogger.warn('BackgroundSync', '$remaining items still pending after retry');
      }
    } catch (e, stack) {
      AppLogger.error('BackgroundSync', 'Sync cycle failed',
          error: e, stack: stack);
    } finally {
      _running = false;
    }
  }

  /// Force an immediate sync (callable from UI)
  static Future<int> syncNow() async {
    if (_running) return 0;
    _running = true;
    try {
      return await SyncService.drainPendingQueue();
    } finally {
      _running = false;
    }
  }

  /// Whether the periodic timer is active
  static bool get isActive => _timer?.isActive ?? false;
}
