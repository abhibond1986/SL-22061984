import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'local_db.dart';
import 'supabase_service.dart';
import 'app_updater.dart';

/// Unique-visitor tracking for the admin dashboard.
///
/// Two different numbers are reported, because they answer different questions:
///   * `uniqueVisitors`  — distinct devices/browsers, INCLUDING people who never
///     signed in. This is "reach".
///   * `uniqueEmployees` — distinct signed-in employee IDs. This is "adoption".
/// The first is always >= the second.
///
/// Identity is a UUID v4 minted once per install and kept in SharedPreferences.
/// Deliberately NOT cleared on logout: the device is still the same device, and
/// clearing it would inflate the visitor count every time someone signs out.
///
/// Everything here is best-effort. A visitor counter must never be able to block
/// startup or surface an error to a safety officer, so every call site swallows
/// failures and the whole service no-ops when Supabase is not configured.
///
/// Requires `supabase_visitors_setup.sql` to have been run once on the backend.
class VisitorService {
  VisitorService._();

  static const String _kVisitorId = 'visitor_id';

  /// Memoises the FUTURE, not the resolved value. Two callers can overlap at
  /// startup (the launch `recordVisit` and a fast `recordLogin`); caching only
  /// the value would let both pass a `null` check, mint two UUIDs and count one
  /// device twice.
  static Future<String>? _idFuture;

  /// Guards against re-reporting on every hot reload / navigation in one run.
  static bool _reportedThisSession = false;

  /// Stable per-install identifier.
  static Future<String> visitorId() => _idFuture ??= _mintOrLoadId();

  static Future<String> _mintOrLoadId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kVisitorId);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = const Uuid().v4();
    await prefs.setString(_kVisitorId, fresh);
    return fresh;
  }

  /// Reports this device to the backend.
  ///
  /// Call once at startup. Pass [force] to report again within the same run
  /// (used after login, so the employee ID gets attached to the existing row).
  static Future<void> recordVisit({bool force = false}) async {
    if (!force && _reportedThisSession) return;
    if (!SupabaseService.isReady) return; // offline / not configured — no-op
    try {
      final id = await visitorId();

      // Attach the employee only if someone is actually signed in. Anonymous
      // visits still count toward uniqueVisitors.
      String? employeeId;
      try {
        final user = await LocalDB.getCurrentUser();
        if (user != null) {
          employeeId = (user['username'] ?? user['employeeId'])?.toString();
          if (employeeId != null && employeeId.trim().isEmpty) employeeId = null;
        }
      } catch (_) {
        // A broken local session must not stop the visit being counted.
      }

      await SupabaseService.client.rpc('record_visit', params: {
        'p_visitor_id': id,
        'p_employee_id': employeeId,
        'p_platform': _platform(),
        'p_app_version': await _appVersion(),
      });
      _reportedThisSession = true;
    } catch (_) {
      // Swallowed on purpose: most likely the SQL has not been run yet, or the
      // device is offline. Neither is worth interrupting anyone over.
    }
  }

  /// Re-reports right after a successful sign-in so the anonymous row picks up
  /// its employee ID.
  static Future<void> recordLogin() => recordVisit(force: true);

  /// Aggregate counts for the admin dashboard.
  ///
  /// Returns null when the stats could NOT be read (RPC missing, offline, bad
  /// shape). Null is deliberately distinct from a zero count — the UI shows "—"
  /// for null so "not set up yet" never masquerades as "nobody has visited".
  static Future<VisitorStats?> fetchStats() async {
    if (!SupabaseService.isReady) return null;
    try {
      final res = await SupabaseService.client.rpc('get_visitor_stats');
      if (res is Map) return VisitorStats.fromMap(Map<String, dynamic>.from(res));
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<String> _appVersion() async {
    try {
      return await AppUpdater.getCurrentVersion();
    } catch (_) {
      return 'unknown';
    }
  }

  static String _platform() {
    // kIsWeb MUST be checked first. On web, `defaultTargetPlatform` reports the
    // HOST operating system, so a browser on a Mac would be recorded as 'ios'.
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'other';
    }
  }
}

/// Immutable snapshot of the aggregate visitor counters.
class VisitorStats {
  final int uniqueVisitors;
  final int uniqueEmployees;
  final int visitorsToday;
  final int visitors7d;
  final int visitors30d;
  final int totalVisits;

  const VisitorStats({
    required this.uniqueVisitors,
    required this.uniqueEmployees,
    required this.visitorsToday,
    required this.visitors7d,
    required this.visitors30d,
    required this.totalVisits,
  });

  factory VisitorStats.fromMap(Map<String, dynamic> m) => VisitorStats(
        uniqueVisitors: _toInt(m['unique_visitors']),
        uniqueEmployees: _toInt(m['unique_employees']),
        visitorsToday: _toInt(m['visitors_today']),
        visitors7d: _toInt(m['visitors_7d']),
        visitors30d: _toInt(m['visitors_30d']),
        totalVisits: _toInt(m['total_visits']),
      );

  /// Postgres `count()` returns bigint, which can arrive over JSON as an int, a
  /// double, or a string depending on magnitude and client. Parse defensively —
  /// a hard cast here would throw inside fetchStats and silently show "—".
  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.round();
    return int.tryParse(v.toString()) ?? 0;
  }
}
