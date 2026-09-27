// lib/services/app_logger.dart
// ★ v25: Structured error logging service.
// Replaces silent catch(_) blocks with traceable, diagnosable error records.
// Stores last 200 log entries in SharedPreferences for admin inspection.

import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

import 'startup_diagnostics.dart';

enum LogLevel { debug, info, warn, error, critical }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String source;   // e.g. 'SyncService', 'GeminiVision'
  final String message;
  final String? details; // stack trace or extra context
  final String? action;  // what was being attempted

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.details,
    this.action,
  });

  Map<String, dynamic> toJson() => {
    'ts': timestamp.toIso8601String(),
    'lvl': level.name,
    'src': source,
    'msg': message,
    if (details != null) 'det': details,
    if (action != null) 'act': action,
  };

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
    timestamp: DateTime.tryParse(j['ts'] ?? '') ?? DateTime.now(),
    level: LogLevel.values.firstWhere(
      (l) => l.name == j['lvl'], orElse: () => LogLevel.info),
    source: j['src'] ?? '',
    message: j['msg'] ?? '',
    details: j['det'],
    action: j['act'],
  );

  @override
  String toString() => '[${level.name.toUpperCase()}] $source: $message';
}

class AppLogger {
  static const String _kLogs = 'app_error_logs';
  static const int _maxEntries = 200;
  static final List<LogEntry> _memoryLog = [];

  /// Log a debug message (only in debug mode)
  static void debug(String source, String message, {String? action}) {
    _log(LogLevel.debug, source, message, action: action);
  }

  /// Log an informational message
  static void info(String source, String message, {String? action}) {
    _log(LogLevel.info, source, message, action: action);
  }

  /// Log a warning (something unexpected but non-fatal)
  static void warn(String source, String message, {String? details, String? action}) {
    _log(LogLevel.warn, source, message, details: details, action: action);
  }

  /// Log an error (operation failed)
  static void error(String source, String message, {Object? error, StackTrace? stack, String? action}) {
    _log(LogLevel.error, source, message,
        details: _details(error, stack, 5), action: action);
  }

  /// Log a critical error (data loss, security, crash)
  static void critical(String source, String message, {Object? error, StackTrace? stack, String? action}) {
    _log(LogLevel.critical, source, message,
        details: _details(error, stack, 10), action: action);
  }

  /// Builds the detail blob, redacted.
  ///
  /// Details end up in SharedPreferences — localStorage on web — and an HTTP
  /// failure's `toString()` carries the full Apps Script deployment URL, while a
  /// Supabase error can carry the anon key from a request header. Storing those
  /// unredacted put credentials somewhere any script on the origin could read
  /// them, against the rule that no sensitive operational data lives in
  /// client-side storage.
  ///
  /// Total by construction: a hostile `toString()` must not turn a logged error
  /// into an unlogged crash.
  static String? _details(Object? error, StackTrace? stack, int stackLines) {
    String safe(Object o, String Function(String) clean) {
      try {
        return clean(o.toString());
      } catch (_) {
        return '[unavailable]';
      }
    }

    final parts = <String>[
      // The message gets the full treatment. The trace keeps its frames and
      // loses only secrets — redacting paths there would leave `[redacted]`
      // repeated ten times and nothing to diagnose from.
      if (error != null) safe(error, StartupDiagnostics.redact),
      if (stack != null)
        safe(stack, StartupDiagnostics.redactSecrets)
            .split('\n')
            .take(stackLines)
            .join('\n'),
    ];
    final det = parts.join('\n');
    return det.isEmpty ? null : det;
  }

  static void _log(LogLevel level, String source, String message,
      {String? details, String? action}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      source: source,
      message: message,
      details: details,
      action: action,
    );

    _memoryLog.add(entry);
    if (_memoryLog.length > _maxEntries) {
      _memoryLog.removeRange(0, _memoryLog.length - _maxEntries);
    }

    // Debug builds only. `debugPrint` is not stripped from a release build — it
    // is an ordinary function that calls `print` — so this line was putting
    // backend URLs, auth-failure details and truncated stack traces into the
    // browser console of the live site. The project rule is that no operational
    // detail reaches a production console; the persisted log plus the admin
    // panel are the production diagnostic path, and `sessionReference` is what a
    // user reads out over the phone.
    if (kDebugMode) {
      debugPrint(entry.toString());
    }

    // Persist errors and above
    if (level.index >= LogLevel.error.index) {
      _persistAsync(entry);
    }
  }

  static Future<void> _persistAsync(LogEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLogs);
      List<Map<String, dynamic>> logs = [];
      if (raw != null) {
        try {
          logs = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        } catch (_) {}
      }
      logs.add(entry.toJson());
      if (logs.length > _maxEntries) {
        logs = logs.sublist(logs.length - _maxEntries);
      }
      await prefs.setString(_kLogs, jsonEncode(logs));
    } catch (_) {
      // Can't log a logging failure — just ignore
    }
  }

  /// Get all persisted error logs (for admin panel)
  static Future<List<LogEntry>> getPersistedLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLogs);
      if (raw == null) return [];
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map((j) => LogEntry.fromJson(j)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Get recent in-memory logs (all levels, current session only)
  static List<LogEntry> getRecentLogs({LogLevel? minLevel}) {
    if (minLevel == null) return List.unmodifiable(_memoryLog);
    return _memoryLog.where((e) => e.level.index >= minLevel.index).toList();
  }

  /// Clear all persisted logs
  static Future<void> clearLogs() async {
    _memoryLog.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLogs);
  }

  /// Get error count since last clear (for badge/indicator)
  static int get errorCount =>
      _memoryLog.where((e) => e.level.index >= LogLevel.error.index).length;

  /// Summary for diagnostics
  static Map<String, dynamic> getSummary() {
    final now = DateTime.now();
    final last24h = _memoryLog.where(
      (e) => now.difference(e.timestamp).inHours < 24);
    return {
      'totalInMemory': _memoryLog.length,
      'errorsLast24h': last24h.where((e) => e.level.index >= LogLevel.error.index).length,
      'warningsLast24h': last24h.where((e) => e.level == LogLevel.warn).length,
      'oldestEntry': _memoryLog.isNotEmpty ? _memoryLog.first.timestamp.toIso8601String() : null,
      'newestEntry': _memoryLog.isNotEmpty ? _memoryLog.last.timestamp.toIso8601String() : null,
    };
  }
}
