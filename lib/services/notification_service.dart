// lib/services/notification_service.dart
// SAIL Safety Lens — FCM Push Notification Service (FREE)
//
// Handles:
//   1. FCM token registration with Apps Script backend
//   2. Foreground notification display
//   3. Background message handling
//   4. Token refresh management

import 'dart:convert';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';
import 'supabase_config.dart';
import 'sync_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  // A getter, not a field: the singleton is created before
  // Firebase.initializeApp() in startForUser, and FirebaseMessaging.instance
  // throws "No Firebase App" if touched that early.
  FirebaseMessaging get _fcm => FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const String _kFcmToken = 'fcm_device_token';
  static const String _kBaseUrlKey = 'apps_script_url';

  // Android notification channel for safety alerts
  static const AndroidNotificationChannel _alertChannel =
      AndroidNotificationChannel(
    'safety_alerts',
    'Safety Alerts',
    description: 'Critical safety incident alerts from SAIL Safety Lens',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
  );

  bool _listening = false;
  String? _registeredFor;
  String _username = 'unknown';
  String _plant = '';

  /// ★ 2026-10-27: entry point used by HomeScreen after sign-in. Until this
  /// date nothing in the app called [init], so no device ever registered a
  /// token and no push could reach anyone.
  ///
  /// Android only: there is a google-services.json for Android but no iOS
  /// GoogleService-Info.plist and no web Firebase config, so on those
  /// platforms this is a no-op (they still get the in-app bell + popup).
  /// Never throws — a push failure must not break sign-in.
  static Future<void> startForUser(Map<String, dynamic>? user) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final username =
        (user?['username']?.toString() ?? '').trim().toLowerCase();
    if (username.isEmpty) return;
    final me = NotificationService();
    if (me._registeredFor == username) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await me.init(
        appsScriptUrl: await SyncService.getBackendUrl(),
        username: username,
        plant: (user?['plant']?.toString() ?? '').trim(),
      );
      me._registeredFor = username;
    } catch (e) {
      debugPrint('[FCM] start failed: $e');
    }
  }

  /// Initialize FCM — call once at app startup
  Future<void> init({required String appsScriptUrl, String? username, String? plant}) async {
    _username = username ?? 'unknown';
    _plant = plant ?? '';
    // Request permission (Android 13+ requires this)
    final settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      print('[FCM] Permission denied');
      return;
    }

    // Get FCM token and register with backend
    final token = await _fcm.getToken();
    if (token != null) {
      await _registerToken(token, appsScriptUrl, _username, _plant);
    }

    // Listeners once per process: a second sign-in on the same phone only
    // re-registers the token under the new username (above).
    if (!_listening) {
      _listening = true;
      // Initialize local notifications for foreground display
      await _initLocalNotifications();
      _fcm.onTokenRefresh.listen((newToken) {
        _registerToken(newToken, appsScriptUrl, _username, _plant);
      });
      // Handle foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      // Handle notification tap (app in background)
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);
    }

    print('[FCM] Initialized successfully. Token: ${token?.substring(0, 20)}...');
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        // Handle notification tap when app is in foreground
        print('[FCM] Notification tapped: ${response.payload}');
      },
    );

    final androidImpl = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    // Android 13+ (API 33) requires an explicit runtime POST_NOTIFICATIONS
    // grant before ANY notification (local or FCM) will display.
    try {
      await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      print('[FCM] Notification permission request failed: $e');
    }

    // Create the notification channel
    await androidImpl?.createNotificationChannel(_alertChannel);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    print('[FCM] Foreground message: ${message.notification?.title}');

    final notification = message.notification;
    if (notification == null) return;

    // Show local notification since FCM doesn't auto-display in foreground
    _localNotifications.show(
      message.hashCode,
      notification.title ?? 'Safety Alert',
      notification.body ?? '',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _alertChannel.id,
          _alertChannel.name,
          channelDescription: _alertChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  void _handleNotificationTap(RemoteMessage message) {
    print('[FCM] Notification opened: ${message.data}');
    // TODO: Navigate to relevant screen based on message.data['ruleId']
  }

  /// Register FCM token with Apps Script backend
  Future<void> _registerToken(String token, String baseUrl, String username, String plant) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kFcmToken, token);
      await prefs.setString(_kBaseUrlKey, baseUrl);

      // Supabase copy (harmless if the device_tokens table is absent).
      if (SupabaseConfig.enabled) {
        try {
          await SupabaseService.registerDeviceToken(
            token: token, username: username, plant: plant, platform: 'android');
        } catch (_) {}
      }

      // ★ 2026-10-27: ALWAYS register with Apps Script too. The sender
      // (sendFcmPushToAll / notifyUsers in apps_script_v14.js) reads the
      // `fcm_devices` sheet, so a token that only reached Supabase — what the
      // old early `return` did — could never be pushed to.
      final data = await SyncService.postAction({
        'action': 'registerDevice',
        'token': token,
        'username': username,
        'plant': plant,
        'platform': 'android',
      });
      debugPrint('[FCM] Device registered: ${data?['action']}');
    } catch (e) {
      print('[FCM] Registration failed: $e');
    }
  }

  /// Unregister device (call on logout)
  Future<void> unregister() async {
    if (_registeredFor == null) return; // never registered this session
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_kFcmToken);
      if (token != null) {
        await SyncService.postAction(
            {'action': 'unregisterDevice', 'token': token});
      }
      await prefs.remove(_kFcmToken);
      _registeredFor = null;
    } catch (e) {
      print('[FCM] Unregister failed: $e');
    }
  }

  /// Get current FCM token (for debugging)
  Future<String?> getToken() async {
    return await _fcm.getToken();
  }
}

/// Top-level function for background message handling
/// Must be a top-level function (not a class method)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print('[FCM-BG] Background message: ${message.notification?.title}');
  // Background notifications are automatically displayed by the system
}
