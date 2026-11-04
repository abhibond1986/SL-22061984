// lib/services/device_permissions_web.dart
//
// Browsers: the site permission is owned by the browser. Asking for it once
// (getUserMedia / geolocation) is what makes the browser show its prompt and
// remember the answer for safetylens.in. See device_permissions.dart.
//
// Notes per browser:
//  * Chrome / Edge / Android Chrome remember Allow and Block per site.
//  * Safari (iPhone, Mac) may ask again in a new session unless the user sets
//    the site to "Allow" in Settings > Safari (or Website Settings).
//  * Firefox cannot report camera/microphone state, so it reads "unknown".

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'device_permissions.dart';

String _name(DeviceFeature f) => switch (f) {
      DeviceFeature.camera => 'camera',
      DeviceFeature.microphone => 'microphone',
      DeviceFeature.location => 'geolocation',
    };

// ★ 2026-11-04: photos on the web go through image_picker_for_web, which uses
// <input type="file" capture>. That opens the phone's own camera app (or a
// file chooser on a laptop) and needs NO browser camera permission. Asking for
// one via getUserMedia({video}) only produced an extra browser prompt and
// switched the camera light on for nothing, so camera is reported as allowed
// and never requested here.
Future<PermissionState> status(DeviceFeature f) async {
  if (f == DeviceFeature.camera) return PermissionState.allowed;
  final perms = html.window.navigator.permissions;
  if (perms == null) return PermissionState.unknown;
  try {
    final s = await perms.query({'name': _name(f)});
    return switch (s.state) {
      'granted' => PermissionState.allowed,
      'denied' => PermissionState.blocked,
      'prompt' => PermissionState.notAsked,
      _ => PermissionState.unknown,
    };
  } catch (_) {
    return PermissionState.unknown;
  }
}

bool _isRefusal(Object e) {
  final m = e.toString().toLowerCase();
  return m.contains('notallowed') ||
      m.contains('permission') ||
      m.contains('denied') ||
      m.contains('securityerror');
}

Future<PermissionState> request(DeviceFeature f) async {
  if (f == DeviceFeature.camera) return PermissionState.allowed;
  if (f == DeviceFeature.location) {
    try {
      await html.window.navigator.geolocation
          .getCurrentPosition(timeout: const Duration(seconds: 20));
      return PermissionState.allowed;
    } catch (e) {
      // PositionError code 1 = PERMISSION_DENIED. Timeout / no fix still
      // means the user allowed it.
      final code = (e is html.PositionError) ? e.code : null;
      if (code == 1) return PermissionState.blocked;
      return code == null && _isRefusal(e)
          ? PermissionState.blocked
          : PermissionState.allowed;
    }
  }
  final media = html.window.navigator.mediaDevices;
  if (media == null) return PermissionState.unknown;
  try {
    final stream = await media.getUserMedia({'audio': true});
    // Only the permission was wanted: release the camera / mic at once.
    for (final t in stream.getTracks()) {
      t.stop();
    }
    return PermissionState.allowed;
  } catch (e) {
    final m = e.toString().toLowerCase();
    if (m.contains('notfound') || m.contains('devicesnotfound')) {
      // No camera/mic hardware (e.g. a desktop without a webcam).
      return PermissionState.unknown;
    }
    return _isRefusal(e) ? PermissionState.blocked : PermissionState.unknown;
  }
}

Future<bool> openSettings() async => false;
