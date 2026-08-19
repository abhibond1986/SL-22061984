// lib/services/sop_ocr_device_stub.dart
//
// WEB build — ML Kit has no web implementation, so on-device recognition is
// simply unavailable and the caller falls back to the AI tier.
//
// Every method must RETURN, never throw. A MissingPluginException escaping from
// here would surface as a crash dialog in the middle of a scan instead of a
// quiet, invisible fallback — which is the whole reason this file exists rather
// than a try/catch at the call site.

import 'dart:typed_data';

class SopOcrDevice {
  /// Always false on web.
  static bool get isAvailable => false;

  /// Human-readable reason, shown in the scan diagnostics line.
  static String get unavailableReason =>
      'on-device text recognition is not available in the browser';

  /// Always empty on web. Callers treat empty as "engine produced nothing" and
  /// move to the next tier.
  static Future<String> recognise(Uint8List jpegBytes) async => '';

  /// Always empty on web.
  ///
  /// Must exist even though it can never do anything: the conditional export in
  /// sop_ocr_device.dart means the two files are ONE type as far as callers are
  /// concerned, so a method added to the ML Kit side and not to this one breaks
  /// the web build only — and the web build is the one that ships to
  /// safetylens.in. Keep the two APIs identical.
  static Future<String> recogniseMultiScript(Uint8List jpegBytes) async => '';

  /// No-op. Kept so the caller can release resources unconditionally.
  static Future<void> dispose() async {}
}
