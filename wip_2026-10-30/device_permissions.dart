// lib/services/device_permissions.dart
//
// Camera, microphone and location: ask ONCE, remember the answer, let the
// user change it in My Profile. (Owner request, 2026-10-30.)
//
// Two layers, kept separate on purpose:
//
//  1. The device/browser permission. Only the operating system (or the
//     browser) can grant or revoke it. The app can ask, read the current state,
//     and send the user to Settings; it cannot switch it off itself.
//
//  2. The user's own choice in this app, stored per user on this device under
//     `device_perm_v1_<username>`. It is what makes the request one-time: once
//     the user has answered the post-login sheet, it is never shown again for
//     that account on this device, at any later login. If they chose "off" for
//     a feature, the feature asks before using it ([guard]) instead of
//     triggering a system prompt, and they can turn it on from My Profile.
//
// The keys are per device on purpose. A permission granted on one phone means
// nothing on another phone, so a new device asks once again.
//
// Sign-out does not clear these keys (LocalDB.signOut only removes the current
// user), and they are not among LocalDB's expendable keys, so web storage
// pressure never evicts them.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';
import 'device_permissions_io.dart'
    if (dart.library.html) 'device_permissions_web.dart' as platform;

enum DeviceFeature { camera, microphone, location }

/// What the device / browser currently says about a permission.
enum PermissionState {
  /// Granted.
  allowed,

  /// Refused, and the app may still ask again.
  denied,

  /// Refused in a way only Settings can undo (Android "Don't allow" twice,
  /// iOS refusal, or a site block in the browser).
  blocked,

  /// Never asked on this device.
  notAsked,

  /// The platform cannot report it (e.g. Firefox for camera/mic). The
  /// browser will ask by itself when the feature is used.
  unknown,
}

class DevicePermissions {
  DevicePermissions._();

  static const String _kPrefix = 'device_perm_v1_';

  /// Bumped whenever a choice changes, so open screens can refresh.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String _user = '';
  static Map<String, dynamic> _prefs = <String, dynamic>{};

  static String _key(String username) =>
      '$_kPrefix${username.trim().toLowerCase()}';

  /// Load the stored choices for [username]. Cheap; call on every login.
  static Future<void> loadFor(String username) async {
    _user = username.trim().toLowerCase();
    _prefs = <String, dynamic>{};
    if (_user.isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key(_user));
      if (raw != null && raw.isNotEmpty) {
        _prefs = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (e) {
      debugPrint('DevicePermissions: load failed: $e');
    }
  }

  static Future<void> _save() async {
    if (_user.isEmpty) return;
    _prefs['updatedAt'] = DateTime.now().toIso8601String();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key(_user), jsonEncode(_prefs));
    } catch (e) {
      // Quota or plugin failure: the choice still holds for this session.
      debugPrint('DevicePermissions: save failed: $e');
    }
    revision.value++;
  }

  /// True once this user has answered the one-time sheet on this device.
  static bool get answered => _prefs['answered'] == true;

  /// The user's in-app choice for [f]. Defaults to on, so nothing changes for
  /// anyone who has not answered yet (the OS still asks as before).
  static bool isEnabled(DeviceFeature f) => _prefs[f.name] != false;

  static Future<void> setEnabled(DeviceFeature f, bool on) async {
    _prefs[f.name] = on;
    await _save();
  }

  /// Record the answers from the one-time sheet.
  static Future<void> recordAnswers(Map<DeviceFeature, bool> choices) async {
    for (final e in choices.entries) {
      _prefs[e.key.name] = e.value;
    }
    _prefs['answered'] = true;
    _prefs['answeredAt'] = DateTime.now().toIso8601String();
    await _save();
  }

  /// Current device/browser state, without prompting.
  static Future<PermissionState> status(DeviceFeature f) async {
    try {
      return await platform.status(f);
    } catch (e) {
      debugPrint('DevicePermissions: status($f) failed: $e');
      return PermissionState.unknown;
    }
  }

  /// Ask the device/browser for [f] (shows the system prompt if it can).
  static Future<PermissionState> request(DeviceFeature f) async {
    try {
      return await platform.request(f);
    } catch (e) {
      debugPrint('DevicePermissions: request($f) failed: $e');
      return PermissionState.unknown;
    }
  }

  /// Open the app's system settings page. False where that is impossible
  /// (web: the user changes it from the padlock in the address bar).
  static Future<bool> openSettings() async {
    try {
      return await platform.openSettings();
    } catch (_) {
      return false;
    }
  }

  static bool get isWeb => kIsWeb;

  // ── Labels ───────────────────────────────────────────────────────────────

  static IconData icon(DeviceFeature f) => switch (f) {
        DeviceFeature.camera => Icons.photo_camera_outlined,
        DeviceFeature.microphone => Icons.mic_none_rounded,
        DeviceFeature.location => Icons.location_on_outlined,
      };

  static String title(DeviceFeature f) => I18n.t('perm.${f.name}');
  static String purpose(DeviceFeature f) => I18n.t('perm.${f.name}.why');

  static String stateLabel(PermissionState s) => I18n.t('perm.state.${s.name}');

  // ── Feature guard ────────────────────────────────────────────────────────

  /// Call before using [f]. Returns true when the feature may go ahead.
  ///
  /// If the user switched [f] off, this asks whether to turn it on instead of
  /// letting the system prompt appear (their choice is respected, and they
  /// are never stuck). Turning it on here is the same as doing it in Profile.
  static Future<bool> guard(BuildContext context, DeviceFeature f) async {
    if (isEnabled(f)) return true;
    final turnOn = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(icon(f)),
        title: Text(I18n.t('perm.offTitle', args: {'feature': title(f)})),
        content: Text(I18n.t('perm.offBody', args: {'feature': title(f)})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(I18n.t('perm.keepOff'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(I18n.t('perm.turnOn'))),
        ],
      ),
    );
    if (turnOn != true) return false;
    await setEnabled(f, true);
    final s = await request(f);
    if (s == PermissionState.blocked && context.mounted) {
      await showBlockedHelp(context, f);
      return false;
    }
    return s != PermissionState.denied;
  }

  /// Explain how to undo a block that only Settings can change.
  static Future<void> showBlockedHelp(BuildContext context, DeviceFeature f) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(icon(f)),
        title: Text(I18n.t('perm.blockedTitle', args: {'feature': title(f)})),
        content: Text(I18n.t(kIsWeb ? 'perm.blockedWeb' : 'perm.blockedApp',
            args: {'feature': title(f)})),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(I18n.t('common.close'))),
          if (!kIsWeb)
            FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openSettings();
                },
                child: Text(I18n.t('perm.openSettings'))),
        ],
      ),
    );
  }
}
