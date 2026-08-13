// lib/services/realtime_sync.dart
//
// Live cross-device sync for incidents (regular reports, AI hazard scans and
// near-miss records all live in the `incidents` table).
//
// Uses Supabase Realtime (Postgres change data capture) to push every INSERT,
// UPDATE and DELETE to all connected devices the instant it happens — so when
// one user adds/edits an AI hazard or near miss, or deletes a record, every
// other user's screen reflects it without a manual refresh.
//
// Design notes:
//  • Offline-first is preserved. This layer only mirrors REMOTE changes into
//    the existing LocalDB cache; screens keep reading LocalDB as before.
//  • Screens don't need bespoke stream plumbing: they listen to the global
//    [incidentsRevision] ValueNotifier and re-run their existing _load().
//  • No-op unless SupabaseConfig.enabled and Supabase initialised.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';
import 'supabase_service.dart';
import 'local_db.dart';
import 'app_logger.dart';
import 'admin_master_data.dart';

class RealtimeSync {
  RealtimeSync._();

  /// Bumped every time a live incident change has been applied to LocalDB.
  /// Screens listen to this and re-run their load to repaint with fresh data.
  static final ValueNotifier<int> incidentsRevision = ValueNotifier<int>(0);

  static RealtimeChannel? _channel;
  static RealtimeChannel? _masterChannel;
  static bool _started = false;

  /// Begin listening for live incident changes. Safe to call more than once.
  static Future<void> start() async {
    if (_started || !SupabaseService.isReady) return;
    _started = true;
    try {
      _channel = SupabaseService.client
          .channel('public:incidents')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'incidents',
            callback: _onChange,
          )
          .subscribe();

      // Master data (plants, departments, severities, statuses, WSA causes,
      // observation types) is edited in the admin panel, possibly on another
      // device. Without this channel an admin edit only reached other devices
      // on their next cold start, so the frontend deviated from the panel.
      _masterChannel = SupabaseService.client
          .channel('public:master_data')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'master_data',
            callback: _onMasterDataChange,
          )
          .subscribe();
      AppLogger.info('RealtimeSync',
          'Subscribed to live incident + master data changes');
    } catch (e, s) {
      _started = false;
      AppLogger.error('RealtimeSync', 'Failed to subscribe',
          error: e, stack: s);
    }
  }

  /// Stop listening (e.g. on logout). Screens keep their last data.
  static Future<void> stop() async {
    try {
      if (_channel != null) {
        await SupabaseService.client.removeChannel(_channel!);
      }
    } catch (_) {}
    try {
      if (_masterChannel != null) {
        await SupabaseService.client.removeChannel(_masterChannel!);
      }
    } catch (_) {}
    _channel = null;
    _masterChannel = null;
    _started = false;
  }

  static bool get isActive => _started;

  // ── master data change handler ────────────────────────────────────────────
  /// Any row change in `master_data` triggers a full re-pull. The payload is
  /// deliberately ignored: rows are key→jsonb, so re-pulling everything is both
  /// simpler and safer than trying to apply one key in isolation, and it also
  /// picks up the AI keys that live outside this table.
  static Future<void> _onMasterDataChange(PostgresChangePayload payload) async {
    try {
      // syncFromBackend() writes to SharedPreferences and bumps
      // AdminMasterData.revision, which is what every screen listens to.
      await AdminMasterData.syncFromBackend();
      AppLogger.info('RealtimeSync', 'Master data refreshed from live change');
    } catch (e, s) {
      AppLogger.error('RealtimeSync', 'Failed to refresh master data',
          error: e, stack: s);
    }
  }

  // ── change handler ────────────────────────────────────────────────────────
  static Future<void> _onChange(PostgresChangePayload payload) async {
    try {
      switch (payload.eventType) {
        case PostgresChangeEvent.insert:
        case PostgresChangeEvent.update:
          final row = Map<String, dynamic>.from(payload.newRecord);
          final inc = SupabaseService.incidentFromRow(row);
          final id = inc['id']?.toString() ?? '';
          if (id.isEmpty) return;
          // A record re-created remotely must be un-tombstoned so it shows.
          await LocalDB.removeDeletedIncidentId(id);
          // MERGE, don't replace. This used to call saveIncident(), which
          // overwrites the whole local record — so an incoming UPDATE wiped
          // the corrective action / closure remarks the user had just typed
          // but not yet pushed, and also dropped device-only fields like the
          // local image reference.
          await LocalDB.saveIncidentFromServer(inc);
          break;
        case PostgresChangeEvent.delete:
          final old = Map<String, dynamic>.from(payload.oldRecord);
          final id = old['id']?.toString() ?? '';
          if (id.isEmpty) return;
          // Remote delete → drop locally too (this also tombstones it so a
          // stale pull can't resurrect it).
          await LocalDB.deleteIncident(id);
          break;
        default:
          return;
      }
      // Tell every listening screen to refresh from LocalDB.
      incidentsRevision.value++;
    } catch (e, s) {
      AppLogger.error('RealtimeSync', 'Failed to apply change',
          error: e, stack: s);
    }
  }
}
