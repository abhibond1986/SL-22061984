// lib/services/device_permissions_io.dart
//
// Android / iOS: permission_handler. See device_permissions.dart.

import 'package:permission_handler/permission_handler.dart';

import 'device_permissions.dart';

Permission _of(DeviceFeature f) => switch (f) {
      DeviceFeature.camera => Permission.camera,
      DeviceFeature.microphone => Permission.microphone,
      DeviceFeature.location => Permission.locationWhenInUse,
    };

PermissionState _map(PermissionStatus s, {required bool afterRequest}) {
  if (s.isGranted || s.isLimited || s.isProvisional) {
    return PermissionState.allowed;
  }
  if (s.isPermanentlyDenied || s.isRestricted) return PermissionState.blocked;
  // Android reports "denied" both before the first request and after a single
  // refusal; only a request can tell them apart.
  return afterRequest ? PermissionState.denied : PermissionState.notAsked;
}

Future<PermissionState> status(DeviceFeature f) async =>
    _map(await _of(f).status, afterRequest: false);

Future<PermissionState> request(DeviceFeature f) async =>
    _map(await _of(f).request(), afterRequest: true);

Future<bool> openSettings() => openAppSettings();
