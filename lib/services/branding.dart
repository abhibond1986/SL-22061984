// lib/services/branding.dart
//
// White-label branding: the company name and logo shown across the app and on
// every PDF report. Set by an admin in Admin → Company Branding.
//
// WHERE IT LIVES
//   * Locally in SharedPreferences under [_prefsKey] (JSON), so the brand is
//     there on first paint with no network — [load] runs before runApp.
//   * Shared via the Supabase `master_data` table under the key 'branding'
//     (pushed by [save], pulled by AdminMasterData.syncFromBackend → [applyRemote]),
//     so one admin change re-brands every device.
//
// DEFAULTS are SAIL's, so an unconfigured install looks exactly as before.
// The default logo is the bundled asset (assets/images/app_icon.png in the app,
// the SAIL emblem in PDFs); a custom logo is stored as a PNG, already resized
// to <= [maxLogoPx] so it stays small enough for a jsonb row and SharedPreferences.
//
// NOT COVERED (static, baked in at build time): web/index.html <title>, the
// favicon / PWA manifest icons, the Android/iOS launcher icon and native splash.
// Those need a rebuild with new assets.

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_service.dart';

class Branding {
  Branding._();

  static const defaultCompanyName = 'Steel Authority of India Limited';
  static const defaultShortName = 'SAIL';
  static const productName = 'Safety Lens';

  /// Longest edge of a stored custom logo, in pixels.
  static const maxLogoPx = 512;

  static const _prefsKey = 'branding_v1';

  /// Bumped on every change. Widgets that show the brand listen to this.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String _companyName = defaultCompanyName;
  static String _shortName = defaultShortName;
  static Uint8List? _logoBytes;
  static int _updatedAt = 0; // ms since epoch; 0 = never customised

  /// Full legal name, e.g. "Steel Authority of India Limited".
  static String get companyName => _companyName;

  /// Short mark shown before "Safety Lens", e.g. "SAIL". May be empty.
  static String get shortName => _shortName;

  /// Custom logo PNG, or null to use the bundled default.
  static Uint8List? get logoBytes => _logoBytes;
  static bool get hasCustomLogo => _logoBytes != null;

  /// "SAIL Safety Lens", or just "Safety Lens" when no short name is set.
  static String get appTitle =>
      _shortName.trim().isEmpty ? productName : '${_shortName.trim()} $productName';

  /// Fallback reporter name when the user has no name on file.
  static String get defaultReporter => _shortName.trim().isEmpty
      ? 'Safety Officer'
      : '${_shortName.trim()} Safety Officer';

  static bool get isDefault =>
      _companyName == defaultCompanyName &&
      _shortName == defaultShortName &&
      _logoBytes == null;

  static DateTime? get updatedAt => _updatedAt == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_updatedAt);

  // ── persistence ─────────────────────────────────────────────────────────

  static Map<String, dynamic> toJson() => {
        'companyName': _companyName,
        'shortName': _shortName,
        'logoB64': _logoBytes == null ? null : base64Encode(_logoBytes!),
        'updatedAt': _updatedAt,
      };

  /// Applies a stored/remote map. Returns true if anything changed.
  static bool _apply(Map m) {
    final name = (m['companyName'] ?? '').toString().trim();
    final short = (m['shortName'] ?? defaultShortName).toString().trim();
    Uint8List? logo;
    final b64 = m['logoB64'];
    if (b64 is String && b64.isNotEmpty) {
      try {
        logo = base64Decode(b64);
      } catch (_) {
        logo = null; // corrupt — fall back to the default logo
      }
    }
    final at = int.tryParse('${m['updatedAt'] ?? 0}') ?? 0;

    final newName = name.isEmpty ? defaultCompanyName : name;
    final changed = newName != _companyName ||
        short != _shortName ||
        !_sameBytes(logo, _logoBytes) ||
        at != _updatedAt;
    _companyName = newName;
    _shortName = short;
    _logoBytes = logo;
    _updatedAt = at;
    if (changed) revision.value++;
    return changed;
  }

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Reads the locally cached brand. Call once before runApp.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is Map) _apply(m);
    } catch (e) {
      debugPrint('[Branding] load failed: $e');
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(toJson()));
  }

  /// Saves locally (immediately visible on this device) and pushes to the
  /// backend so every other device picks it up on its next sync.
  ///
  /// Returns true if the backend accepted it; false means it is saved on this
  /// device only (offline / backend unavailable) — the caller should say so.
  static Future<bool> save({
    required String companyName,
    required String shortName,
    required Uint8List? logoBytes,
    String? updatedBy,
  }) async {
    _apply({
      'companyName': companyName,
      'shortName': shortName,
      'logoB64': logoBytes == null ? null : base64Encode(logoBytes),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await _persist();
    try {
      return await SyncService.pushMasterData(
          branding: toJson(), updatedBy: updatedBy);
    } catch (e) {
      debugPrint('[Branding] push failed: $e');
      return false;
    }
  }

  /// Restores the SAIL defaults everywhere.
  static Future<bool> resetToDefault({String? updatedBy}) => save(
      companyName: defaultCompanyName,
      shortName: defaultShortName,
      logoBytes: null,
      updatedBy: updatedBy);

  /// Called by AdminMasterData.syncFromBackend with the 'branding' row.
  /// Last write wins by `updatedAt`, so a pull that lands just after a local
  /// save (before its push reached the server) cannot roll the save back.
  static Future<bool> applyRemote(dynamic remote) async {
    if (remote is! Map) return false;
    final at = int.tryParse('${remote['updatedAt'] ?? 0}') ?? 0;
    if (at < _updatedAt) return false;
    final changed = _apply(remote);
    if (changed) await _persist();
    return changed;
  }
}
