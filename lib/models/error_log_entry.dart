// lib/models/error_log_entry.dart
// Error log entry model for tracking AI failures and system errors

class ErrorLogEntry {
  final String id;
  final DateTime timestamp;
  final String errorType;
  final String errorMessage;
  final String? stackTrace;
  final String userId;
  final String userName;
  final String plant;
  final String? department;
  final String? apiEndpoint;
  final String? requestData;
  final String? responseData;
  final int? httpStatusCode;
  final String appVersion;
  final String platform;

  ErrorLogEntry({
    required this.id,
    required this.timestamp,
    required this.errorType,
    required this.errorMessage,
    this.stackTrace,
    required this.userId,
    required this.userName,
    required this.plant,
    this.department,
    this.apiEndpoint,
    this.requestData,
    this.responseData,
    this.httpStatusCode,
    required this.appVersion,
    required this.platform,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'errorType': errorType,
      'errorMessage': errorMessage,
      'stackTrace': stackTrace,
      'userId': userId,
      'userName': userName,
      'plant': plant,
      'department': department,
      'apiEndpoint': apiEndpoint,
      'requestData': requestData,
      'responseData': responseData,
      'httpStatusCode': httpStatusCode,
      'appVersion': appVersion,
      'platform': platform,
    };
  }

  factory ErrorLogEntry.fromMap(Map<String, dynamic> map) {
    return ErrorLogEntry(
      id: map['id'] ?? '',
      timestamp: DateTime.parse(map['timestamp'] ?? DateTime.now().toIso8601String()),
      errorType: map['errorType'] ?? 'UNKNOWN',
      errorMessage: map['errorMessage'] ?? '',
      stackTrace: map['stackTrace'],
      userId: map['userId'] ?? '',
      userName: map['userName'] ?? '',
      plant: map['plant'] ?? '',
      department: map['department'],
      apiEndpoint: map['apiEndpoint'],
      requestData: map['requestData'],
      responseData: map['responseData'],
      httpStatusCode: map['httpStatusCode'],
      appVersion: map['appVersion'] ?? '',
      platform: map['platform'] ?? '',
    );
  }

  String toJson() {
    return '''
{
  "id": "$id",
  "timestamp": "${timestamp.toIso8601String()}",
  "errorType": "$errorType",
  "errorMessage": "$errorMessage",
  "userId": "$userId",
  "plant": "$plant",
  "apiEndpoint": "$apiEndpoint",
  "appVersion": "$appVersion"
}
''';
  }
}

// Error type constants
class ErrorType {
  static const String AI_ANALYSIS_FAILED = 'AI_ANALYSIS_FAILED';
  static const String CHAT_API_FAILED = 'CHAT_API_FAILED';
  static const String API_TIMEOUT = 'API_TIMEOUT';
  static const String PARSE_ERROR = 'PARSE_ERROR';
  static const String NETWORK_ERROR = 'NETWORK_ERROR';
  static const String BACKEND_SYNC_FAILED = 'BACKEND_SYNC_FAILED';
  static const String IMAGE_PROCESSING_ERROR = 'IMAGE_PROCESSING_ERROR';
  static const String DATABASE_ERROR = 'DATABASE_ERROR';
  static const String UNKNOWN_ERROR = 'UNKNOWN_ERROR';
}
