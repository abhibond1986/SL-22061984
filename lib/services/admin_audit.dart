// lib/services/admin_audit.dart
// SAIL Safety Lens — Admin Audit Log Service
//
// Records every administrative action for compliance and forensics.
// Stored locally in SharedPreferences. Capped at 5000 entries (FIFO).
//
// Usage:
//   await AdminAudit.log(
//     action: 'incident_closed',
//     actor: 'admin',
//     target: incidentId,
//     meta: {'plant': 'BSP', 'severity': 'CRITICAL'},
//   );

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';

class AdminAudit {
  static const String _kKey      = 'admin_audit_log';
  static const int    _maxEntries = 5000;

  // Standard action codes — use these strings as `action` for filterability
  static const String actLoginOk        = 'login_success';
  static const String actLoginFail      = 'login_failed';
  static const String actLogout         = 'logout';
  static const String actUserAdd        = 'user_added';
  static const String actUserEdit       = 'user_edited';
  static const String actUserDelete     = 'user_deleted';
  static const String actUserRoleChange = 'user_role_changed';
  static const String actUserStatus     = 'user_status_changed';
  static const String actUserPwReset    = 'user_password_reset';
  static const String actIncClose       = 'incident_closed';
  static const String actIncDelete      = 'incident_deleted';
  static const String actIncAssign      = 'incident_assigned';
  static const String actIncStatus      = 'incident_status_changed';
  static const String actBulkDelete     = 'bulk_delete';
  static const String actBulkClose      = 'bulk_close';
  static const String actBulkExport     = 'bulk_export';
  static const String actKbAdd          = 'kb_added';
  static const String actKbDelete       = 'kb_deleted';
  static const String actKbSeed         = 'kb_seeded';
  static const String actResetAll       = 'reset_all_data';
  static const String actSettingsChange = 'settings_changed';
  static const String actPwChange       = 'admin_password_changed';
  static const String actExport         = 'data_exported';
  static const String actSync           = 'sync_triggered';
  static const String actSysCheck       = 'system_health_check';
  static const String actAlertRuleAdd   = 'alert_rule_added';
  static const String actAlertRuleDel   = 'alert_rule_deleted';
  static const String actBackup         = 'backup_created';
  static const String actRestore        = 'backup_restored';

  // ── LOG ─────────────────────────────────────────────────────────
  static Future<void> log({
    required String action,
    required String actor,
    String? target,
    String? targetName,
    Map<String, dynamic>? meta,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kKey);
      final list  = raw == null ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();

      list.insert(0, {
        'id'        : DateTime.now().microsecondsSinceEpoch.toString(),
        'timestamp' : DateTime.now().toIso8601String(),
        'action'    : action,
        'actor'     : actor,
        if (target     != null) 'target'     : target,
        if (targetName != null) 'targetName' : targetName,
        if (meta       != null) 'meta'       : meta,
      });

      // FIFO cap
      if (list.length > _maxEntries) {
        list.removeRange(_maxEntries, list.length);
      }

      await prefs.setString(_kKey, jsonEncode(list));
    } catch (_) {
      // Audit log failure should never break the app
    }
    // Server copy (Phase 1C). The local list above is per-device and can be
    // cleared by whoever holds the device, so it cannot back an audit claim on
    // its own. Fire-and-forget: never delays or fails the admin action.
    SupabaseService.logAuditEvent(
      actor: actor,
      action: action,
      target: target,
      detail: {
        if (targetName != null) 'targetName': targetName,
        if (meta != null) ...meta,
      },
    ).ignore();
  }

  // ── READ ────────────────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getLog({
    int? limit,
    String? action,        // exact match on `action` field
    String? actor,         // exact match on `actor` field
    String? search,        // case-insensitive substring across action+actor+target+targetName
    DateTime? from,
    DateTime? to,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw   = prefs.getString(_kKey);
      if (raw == null) return [];

      var list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (action != null) {
        list = list.where((e) => e['action'] == action).toList();
      }
      if (actor != null) {
        list = list.where((e) => e['actor'] == actor).toList();
      }
      if (from != null || to != null) {
        list = list.where((e) {
          final ts = DateTime.tryParse(e['timestamp']?.toString() ?? '');
          if (ts == null) return false;
          if (from != null && ts.isBefore(from)) return false;
          if (to   != null && ts.isAfter(to))    return false;
          return true;
        }).toList();
      }
      if (search != null && search.trim().isNotEmpty) {
        final q = search.toLowerCase();
        list = list.where((e) {
          final s = [
            e['action'], e['actor'], e['target'], e['targetName'],
          ].whereType<String>().join(' ').toLowerCase();
          return s.contains(q);
        }).toList();
      }

      if (limit != null && list.length > limit) {
        list = list.sublist(0, limit);
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  // ── COUNTS ──────────────────────────────────────────────────────
  static Future<int> count() async {
    final l = await getLog();
    return l.length;
  }

  static Future<Map<String, int>> countByAction() async {
    final list = await getLog();
    final m = <String, int>{};
    for (final e in list) {
      final a = e['action']?.toString() ?? '?';
      m[a] = (m[a] ?? 0) + 1;
    }
    return m;
  }

  static Future<Map<String, int>> countByActor() async {
    final list = await getLog();
    final m = <String, int>{};
    for (final e in list) {
      final a = e['actor']?.toString() ?? '?';
      m[a] = (m[a] ?? 0) + 1;
    }
    return m;
  }

  // ── CLEAR ───────────────────────────────────────────────────────
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }

  // ── EXPORT AS CSV ───────────────────────────────────────────────
  static Future<String> exportCsv({
    String? action, String? actor,
    DateTime? from, DateTime? to,
  }) async {
    final list = await getLog(
      action: action, actor: actor, from: from, to: to);

    final buf = StringBuffer();
    buf.writeln('Timestamp,Action,Actor,Target,Target Name,Meta');

    String esc(String? s) {
      if (s == null) return '';
      final v = s.replaceAll('"', '""');
      return '"$v"';
    }

    for (final e in list) {
      final metaStr = e['meta'] is Map
          ? jsonEncode(e['meta']) : (e['meta']?.toString() ?? '');
      buf.writeln([
        esc(e['timestamp']?.toString()),
        esc(e['action']?.toString()),
        esc(e['actor']?.toString()),
        esc(e['target']?.toString()),
        esc(e['targetName']?.toString()),
        esc(metaStr),
      ].join(','));
    }
    return buf.toString();
  }

  // ── HUMAN-READABLE ACTION LABELS ────────────────────────────────
  static String label(String action) {
    switch (action) {
      case actLoginOk        : return 'Login (success)';
      case actLoginFail      : return 'Login (failed)';
      case actLogout         : return 'Logout';
      case actUserAdd        : return 'User added';
      case actUserEdit       : return 'User edited';
      case actUserDelete     : return 'User deleted';
      case actUserRoleChange : return 'User role changed';
      case actUserStatus     : return 'User status changed';
      case actUserPwReset    : return 'User password reset';
      case actIncClose       : return 'Incident closed';
      case actIncDelete      : return 'Incident deleted';
      case actIncAssign      : return 'Incident assigned';
      case actIncStatus      : return 'Incident status changed';
      case actBulkDelete     : return 'Bulk delete';
      case actBulkClose      : return 'Bulk close';
      case actBulkExport     : return 'Bulk export';
      case actKbAdd          : return 'KB entry added';
      case actKbDelete       : return 'KB entry deleted';
      case actKbSeed         : return 'KB seeded';
      case actResetAll       : return 'All data reset';
      case actSettingsChange : return 'Settings changed';
      case actPwChange       : return 'Admin password changed';
      case actExport         : return 'Data exported';
      case actSync           : return 'Sync triggered';
      case actSysCheck       : return 'System health checked';
      case actAlertRuleAdd   : return 'Alert rule added';
      case actAlertRuleDel   : return 'Alert rule deleted';
      case actBackup         : return 'Backup created';
      case actRestore        : return 'Backup restored';
      default                : return action.replaceAll('_', ' ');
    }
  }
}
