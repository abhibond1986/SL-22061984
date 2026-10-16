// lib/services/action_photo.dart
// SAIL Safety Lens — the optional "after" photo the action owner attaches to
// the corrective action (2026-10-16).
//
// Stored on the incident as:
//   actionImageBase64 — on the device until the push uploads it (device-only)
//   actionImageUrl    — public Storage URL (`act_<id>.jpg`), synced
//   actionImageAt     — when it was attached
//
// One resolver for the detail screen AND the PDF, so the photo on paper is
// always the photo on screen.

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

class ActionPhoto {
  ActionPhoto._();

  /// Longest edge and JPEG quality. ~80–150KB: enough to see that a guard is
  /// back on, small enough for the device's local store.
  static const int maxEdge = 1024;
  static const int quality = 68;

  static bool has(Map<String, dynamic> inc) =>
      (inc['actionImageBase64']?.toString() ?? '').isNotEmpty ||
      (inc['actionImageUrl']?.toString() ?? '').startsWith('http');

  /// Shrink a picked photo to [maxEdge]. Returns the input unchanged if it
  /// cannot be decoded (the picker already limited it) or is already small.
  static Uint8List compress(Uint8List bytes) {
    try {
      final d = img.decodeImage(bytes);
      if (d == null) return bytes;
      final big = d.width > maxEdge || d.height > maxEdge;
      if (!big && bytes.lengthInBytes < 200 * 1024) return bytes;
      final r = !big
          ? d
          : (d.width >= d.height
              ? img.copyResize(d, width: maxEdge)
              : img.copyResize(d, height: maxEdge));
      return Uint8List.fromList(img.encodeJpg(r, quality: quality));
    } catch (_) {
      return bytes;
    }
  }

  static final Map<String, Uint8List> _cache = {};

  /// The photo's bytes, or null when there is none or it cannot be fetched.
  static Future<Uint8List?> resolve(Map<String, dynamic> inc) async {
    final b64 = inc['actionImageBase64']?.toString() ?? '';
    if (b64.isNotEmpty) {
      try { return base64Decode(b64); } catch (_) {}
    }
    final url = inc['actionImageUrl']?.toString() ?? '';
    if (!url.startsWith('http')) return null;
    final hit = _cache[url];
    if (hit != null) return hit;
    try {
      final r = await http.get(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
        _cache[url] = r.bodyBytes;
        return r.bodyBytes;
      }
    } catch (_) {}
    return null;
  }
}
