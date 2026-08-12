// lib/services/error_log_service.dart
// Central error logging service for tracking AI failures and system errors

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/error_log_entry.dart';
import 'sync_service.dart';
import 'local_db.dart';

class ErrorLogService {
  static const String _kErrorLogs = 'error_logs';
  static const int _maxLocalLogs = 500; // Keep last 500 errors locally

  /// Log an error
  static Future<void> logError(ErrorLogEntry entry) async {
    try {
      // 1. Save to local storage
      await _saveToLocal(entry);

      // 2. Push to backend (fire-and-forget)
      SyncService.pushErrorLog(entry.toMap()).catchError((e) {
        print('ErrorLogService: Failed to push error to backend: $e');
        return false;
      });

      // 3. Check failure rate and alert if needed
      _checkFailureRate();

      // 4. Debug log
      print('ErrorLogService: Logged ${entry.errorType} - ${entry.errorMessage}');
    } catch (e) {
      // Don't throw - error logging itself shouldn't break the app
      print('ErrorLogService: Failed to log error: $e');
    }
  }

  /// Save error to local storage
  static Future<void> _saveToLocal(ErrorLogEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await _getLocalLogs();

      // Add new error
      existing.add(entry.toMap());

      // Keep only last N errors to prevent storage bloat
      if (existing.length > _maxLocalLogs) {
        existing.removeRange(0, existing.length - _maxLocalLogs);
      }

      // Save back
      await prefs.setString(_kErrorLogs, jsonEncode(existing));
    } catch (e) {
      print('ErrorLogService: Failed to save to local: $e');
    }
  }

  /// Get all error logs from local storage
  static Future<List<Map<String, dynamic>>> _getLocalLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kErrorLogs);
      if (raw == null) return [];

      final list = jsonDecode(raw) as List;
      return list.map((e) => e as Map<String, dynamic>).toList();
    } catch (e) {
      print('ErrorLogService: Failed to get local logs: $e');
      return [];
    }
  }

  /// Get error logs with filters
  static Future<List<ErrorLogEntry>> getErrors({
    DateTime? startDate,
    DateTime? endDate,
    String? errorType,
    String? plant,
    String? userId,
  }) async {
    try {
      final logs = await _getLocalLogs();

      // Parse to ErrorLogEntry objects
      var entries = logs.map((log) {
        try {
          return ErrorLogEntry.fromMap(log);
        } catch (e) {
          print('ErrorLogService: Failed to parse log entry: $e');
          return null;
        }
      }).whereType<ErrorLogEntry>().toList();

      // Apply filters
      if (startDate != null) {
        entries = entries.where((e) =>
          e.timestamp.isAfter(startDate) ||
          e.timestamp.isAtSameMomentAs(startDate)
        ).toList();
      }

      if (endDate != null) {
        entries = entries.where((e) =>
          e.timestamp.isBefore(endDate) ||
          e.timestamp.isAtSameMomentAs(endDate)
        ).toList();
      }

      if (errorType != null && errorType.isNotEmpty) {
        entries = entries.where((e) => e.errorType == errorType).toList();
      }

      if (plant != null && plant.isNotEmpty) {
        entries = entries.where((e) => e.plant == plant).toList();
      }

      if (userId != null && userId.isNotEmpty) {
        entries = entries.where((e) => e.userId == userId).toList();
      }

      // Sort by timestamp (newest first)
      entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return entries;
    } catch (e) {
      print('ErrorLogService: Failed to get errors: $e');
      return [];
    }
  }

  /// Get error statistics
  static Future<Map<String, dynamic>> getErrorStats({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final errors = await getErrors(startDate: startDate, endDate: endDate);

      final stats = {
        'totalErrors': errors.length,
        'aiAnalysisFailed': errors.where((e) =>
          e.errorType == ErrorType.AI_ANALYSIS_FAILED).length,
        'chatApiFailed': errors.where((e) =>
          e.errorType == ErrorType.CHAT_API_FAILED).length,
        'apiTimeout': errors.where((e) =>
          e.errorType == ErrorType.API_TIMEOUT).length,
        'parseError': errors.where((e) =>
          e.errorType == ErrorType.PARSE_ERROR).length,
        'networkError': errors.where((e) =>
          e.errorType == ErrorType.NETWORK_ERROR).length,
        'backendSyncFailed': errors.where((e) =>
          e.errorType == ErrorType.BACKEND_SYNC_FAILED).length,
      };

      // Group by plant
      final byPlant = <String, int>{};
      for (var error in errors) {
        byPlant[error.plant] = (byPlant[error.plant] ?? 0) + 1;
      }
      stats['byPlant'] = byPlant;

      // Group by API endpoint
      final byApi = <String, int>{};
      for (var error in errors) {
        if (error.apiEndpoint != null && error.apiEndpoint!.isNotEmpty) {
          byApi[error.apiEndpoint!] = (byApi[error.apiEndpoint!] ?? 0) + 1;
        }
      }
      stats['byApi'] = byApi;

      return stats;
    } catch (e) {
      print('ErrorLogService: Failed to get stats: $e');
      return {};
    }
  }

  /// Check if failure rate is concerning and alert admin
  static Future<void> _checkFailureRate() async {
    try {
      final last24h = DateTime.now().subtract(const Duration(hours: 24));
      final recentErrors = await getErrors(startDate: last24h);

      // Alert if more than 10 errors in 24 hours
      if (recentErrors.length > 10) {
        print('⚠️ ErrorLogService: HIGH FAILURE RATE - ${recentErrors.length} errors in 24h');
        // TODO: Add push notification to admin
      }

      // Check AI-specific failure rate
      final aiFailures = recentErrors.where((e) =>
        e.errorType == ErrorType.AI_ANALYSIS_FAILED ||
        e.errorType == ErrorType.CHAT_API_FAILED
      ).length;

      if (aiFailures > 5) {
        print('⚠️ ErrorLogService: HIGH AI FAILURE RATE - $aiFailures AI failures in 24h');
        // TODO: Add specific AI failure alert
      }
    } catch (e) {
      print('ErrorLogService: Failed to check failure rate: $e');
    }
  }

  /// Clear old errors (for admin cleanup)
  static Future<void> clearOldErrors({int daysToKeep = 30}) async {
    try {
      final cutoffDate = DateTime.now().subtract(Duration(days: daysToKeep));
      final errors = await getErrors();

      final filtered = errors.where((e) =>
        e.timestamp.isAfter(cutoffDate)
      ).toList();

      final prefs = await SharedPreferences.getInstance();
      final maps = filtered.map((e) => e.toMap()).toList();
      await prefs.setString(_kErrorLogs, jsonEncode(maps));

      print('ErrorLogService: Cleared errors older than $daysToKeep days');
    } catch (e) {
      print('ErrorLogService: Failed to clear old errors: $e');
    }
  }

  /// Clear all errors (for admin)
  static Future<void> clearAllErrors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kErrorLogs);
      print('ErrorLogService: Cleared all errors');
    } catch (e) {
      print('ErrorLogService: Failed to clear all errors: $e');
    }
  }

  /// Export errors to CSV format
  static Future<String> exportToCSV({
    DateTime? startDate,
    DateTime? endDate,
    String? errorType,
  }) async {
    try {
      final errors = await getErrors(
        startDate: startDate,
        endDate: endDate,
        errorType: errorType,
      );

      final csv = StringBuffer();

      // Header
      csv.writeln('Timestamp,Type,Message,User,Plant,Department,API Endpoint,Platform,App Version');

      // Data rows
      for (var error in errors) {
        csv.writeln(
          '${error.timestamp.toIso8601String()},'
          '"${error.errorType}",'
          '"${_escapeCsv(error.errorMessage)}",'
          '"${error.userName} (${error.userId})",'
          '"${error.plant}",'
          '"${error.department ?? ''}",'
          '"${error.apiEndpoint ?? ''}",'
          '"${error.platform}",'
          '"${error.appVersion}"'
        );
      }

      return csv.toString();
    } catch (e) {
      print('ErrorLogService: Failed to export to CSV: $e');
      return '';
    }
  }

  /// Escape CSV special characters
  static String _escapeCsv(String text) {
    return text.replaceAll('"', '""').replaceAll('\n', ' ').replaceAll('\r', '');
  }

  /// Get success rate (for display in admin panel)
  /// Requires tracking successful operations (to be implemented)
  static Future<double> getSuccessRate({DateTime? startDate}) async {
    try {
      final errors = await getErrors(startDate: startDate);

      // TODO: Track successful operations to calculate real success rate
      // For now, return approximate based on error count
      // Assuming ~100 operations per day, success rate = (100 - errors) / 100

      if (errors.isEmpty) return 100.0;
      if (errors.length >= 100) return 0.0;

      return ((100 - errors.length) / 100.0) * 100.0;
    } catch (e) {
      print('ErrorLogService: Failed to get success rate: $e');
      return 0.0;
    }
  }
}
