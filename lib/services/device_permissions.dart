// lib/services/device_permissions.dart
//
// Camera, microphone and location. (Owner request 2026-10-30; simplified
// 2026-11-04.)
//
// ★ 2026-11-04 — ONE prompt per permission, asked at first use.
// The 2026-10-30 version showed an in-app sheet after login and then fired the
// browser / OS prompt for each ticked item, so every permission was asked
// twice (owner: "annoying ... duplicacy of permission"). The sheet is gone.
// Now the only prompt is the device's own, shown the first time the user
// actually taps the camera, the mic or a GPS capture, with the reason obvious
// from what they just tapped. Rules that keep it to one prompt:
//   * [guard] never calls [request] itself; the feature's own plugin
//     (image_picker / speech_to_text / geolocator) triggers the single system
//     prompt. [guard] only reads [status] (no prompt) so a BLOCKED permission
//     gets clear "how to unblock" help instead of a silent failure.
//   * On the web the camera needs no browser permission at all: image_picker
//     uses <input type=file capture>, which opens the phone's camera app.
//     The old getUserMedia({video}) probe produced a browser prompt for
//     nothing. See device_permissions_web.dart.
//   * The storage key moved v1 -> v2: "Not now" on the old sheet saved all
//     three as OFF, which would have kept those users on a double prompt
//     (in-app "turned off" dialog + browser prompt). Everyone starts ON again;
//     the My Profile switches still let a user opt out on purpose.
//
// Two layers, kept separate on purpose:
//
//  1. The device/browser permission. Only the operating system (or the
//     browser) can grant or revoke it. The app can read the current state and
//     send the user to Settings; it cannot switch it off itself.
//
//  2. The user's own choice in this app (My Profile switches), stored per user
//     on this device under `device_perm_v2_<username>`. Default ON. If they
//     switched a feature off, [guard] asks before using it.
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

  static const String _kPrefix = 'device_perm_v2_';

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

  /// The user's in-app choice for [f] (My Profile switch). Defaults to on:
  /// the device simply asks the first time the feature is used.
  static bool isEnabled(DeviceFeature f) => _prefs[f.name] != false;

  static Future<void> setEnabled(DeviceFeature f, bool on) async {
    _prefs[f.name] = on;
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
  /// Never shows a system prompt itself: the feature that runs next does
  /// that, once (see the file header). This only
  ///  * respects a My Profile "off" switch (asks whether to turn it back on),
  ///  * and, if the device already reports [f] as BLOCKED, explains how to
  ///    unblock it instead of letting the feature fail silently.
  static Future<bool> guard(BuildContext context, DeviceFeature f) async {
    if (!isEnabled(f)) {
      if (!await _askTurnOn(context, f)) return false;
      await setEnabled(f, true);
    }
    final s = await status(f);
    if (s == PermissionState.blocked) {
      if (context.mounted) await showBlockedHelp(context, f);
      return false;
    }
    return true;
  }

  static Future<bool> _askTurnOn(BuildContext context, DeviceFeature f) async {
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
    return turnOn == true;
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
