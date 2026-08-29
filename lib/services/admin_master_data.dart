// lib/services/admin_master_data.dart
// SAIL Safety Lens — Master data + Custom list editor storage
//
// Constants for SAIL plants, default WSA causes, default departments.
// Plus storage hooks for user-edited custom lists.

import 'dart:convert';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_service.dart';
// For the canonical list of Gemini vision model IDs, so backend-synced values
// are validated against ONE source of truth rather than a duplicated list that
// would drift as Google retires models. (Dart permits the resulting import
// cycle; gemini_direct_vision.dart imports this file for the admin vocabularies.)
import 'gemini_direct_vision.dart';
// Imported for the OpenRouter pref-key constants only, so the pref names live
// in exactly one place. gemini_vision.dart imports this file in turn; Dart
// permits the cycle and it is preferable to duplicating string literals that
// must match for key sync to work at all.
import 'gemini_vision.dart';
// For the NaraVision pref-key names, key prefix and model list — the Tier 1b
// key and model are synced here.
import 'nara_vision.dart';

class AdminMasterData {
  // ── LIVE CHANGE NOTIFICATION ─────────────────────────────────────
  // Bumped whenever ANY master list changes — local admin edit, backend
  // pull, or realtime push. Screens listen and reload their dropdowns so
  // an admin edit never requires an app restart.
  //
  // Usage in a StatefulWidget:
  //   AdminMasterData.revision.addListener(_reloadMasterData);   // initState
  //   AdminMasterData.revision.removeListener(_reloadMasterData); // dispose
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static void _bump() {
    _wsaSnapshot = null; // force a re-read on next synchronous access
    revision.value++;
  }

  // ── SYNCHRONOUS WSA SNAPSHOT ─────────────────────────────────────
  // A few code paths (notably LocalAI.processText, which the near-miss form
  // calls inline) are synchronous and cannot await getWsaCauses(). Rather than
  // let them fall back to a re-typed hardcoded copy — which is exactly how the
  // admin panel and the frontend drifted apart — they read this cache.
  // Kept warm by [primeSnapshots], called at startup and after every change.
  static List<String>? _wsaSnapshot;

  /// Best-effort synchronous view of the admin's WSA cause list. Falls back to
  /// the shared defaults until [primeSnapshots] has run at least once — never
  /// to a private duplicate of the list.
  static List<String> get wsaCausesSync =>
      _wsaSnapshot ?? List<String>.from(defaultWsaCauses);

  // ── SYNCHRONOUS SOP-SCAN-TAB SNAPSHOT ────────────────────────────
  // The bottom navigation bar in home_screen.dart is rebuilt synchronously on
  // every frame and cannot await getSopScanTabVisible(). Without a synchronous
  // view, the tab renders on the first frame and disappears on the second — a
  // visible flicker, and worse, it means a normal user sees a tab they are not
  // supposed to have for long enough to tap it.
  //
  // NOTE this cache behaves DIFFERENTLY from [_wsaSnapshot] on purpose:
  // _bump() does NOT clear it. It is write-through — every one of the three
  // places that writes the pref also sets this field (setSopScanTabVisible, the
  // syncFromBackend pull, and resetToDefaults). Clearing it on _bump would make
  // the flag read false — hiding the tab — for the whole async gap until
  // primeSnapshots() finished, so an unrelated master-data edit would blink the
  // tab off for every user who is allowed to see it. A bool has a known new
  // value at write time; a list does not, which is why the list invalidates and
  // this does not.
  static bool? _sopScanTabSnapshot;

  /// Best-effort synchronous view of "is the SOP Scan tab released to normal
  /// users". Defaults to FALSE — hidden — until primed, which is the fail-safe
  /// direction: an unreleased feature staying hidden one frame too long is
  /// harmless, showing it one frame too early is the thing being prevented.
  ///
  /// Admins are shown the tab regardless of this flag; that decision lives at
  /// the call site in home_screen.dart, not here, because this getter answers
  /// only "has it been released" and must not be confused with "may I see it".
  static bool get sopScanTabVisibleSync => _sopScanTabSnapshot ?? false;

  /// Warm the synchronous caches. Call once during app startup, and again
  /// whenever master data changes (the revision listener in main does this).
  static Future<void> primeSnapshots() async {
    try {
      _wsaSnapshot = await getWsaCauses();
    } catch (_) {}
    // Separate try: a failure reading the WSA list must not leave the SOP flag
    // unprimed, and vice versa. One shared try block would couple two unrelated
    // settings through a single catch.
    try {
      _sopScanTabSnapshot = await getSopScanTabVisible();
    } catch (_) {}
  }

  /// The admin's cause whose leading number matches [number] (e.g. 12 →
  /// '12. Inadequate isolation (LOTO/PTW)'). Returns null if the admin has no
  /// such entry, so callers can degrade instead of asserting a stale label.
  static String? wsaCauseByNumber(int number) {
    for (final c in wsaCausesSync) {
      final m = RegExp(r'^\s*(\d+)\s*\.').firstMatch(c);
      if (m != null && int.tryParse(m.group(1)!) == number) return c;
    }
    return null;
  }

  /// Set when a push to the backend fails, so the admin UI can warn that
  /// the edit is local-only instead of silently diverging from the server.
  static final ValueNotifier<String?> lastPushError =
      ValueNotifier<String?>(null);

  static void _pushGuarded(Future<bool> Function() push, String what) {
    push().then((ok) {
      lastPushError.value = ok ? null : 'Failed to save $what to server';
    }).catchError((e) {
      lastPushError.value = 'Failed to save $what to server: $e';
      return null;
    });
  }

  /// ★ FIX: Push with retry — enqueue to pending queue on failure so
  /// BackgroundSync retries later. Unlike incidents (which have deep payloads),
  /// master data is a full-replace, so we store the complete data to push.
  static void _pushWithRetry(
      Future<bool> Function() push, String what, String action,
      Map<String, dynamic> payload) {
    push().then((ok) {
      if (ok) {
        lastPushError.value = null;
      } else {
        lastPushError.value = 'Failed to save $what to server (queued for retry)';
        _enqueueMasterData(action, payload);
      }
    }).catchError((e) {
      lastPushError.value = 'Failed to save $what to server (queued for retry): $e';
      _enqueueMasterData(action, payload);
      return null;
    });
  }

  static Future<void> _enqueueMasterData(
      String action, Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const queueKey = 'sync_pending_queue';
      final raw = prefs.getString(queueKey);
      final queue = raw != null ? (jsonDecode(raw) as List) : [];
      queue.add({
        'action': action,
        'payload': payload,
        'queuedAt': DateTime.now().toIso8601String(),
      });
      await prefs.setString(queueKey, jsonEncode(queue));
    } catch (_) {}
  }

  // ── SAIL PLANTS (14 units + Others) ──────────────────────────────
  static const List<Map<String, String>> sailPlants = [
    {'code': 'BSP',        'name': 'Bhilai Steel Plant',          'state': 'Chhattisgarh', 'kind': 'Plant'},
    {'code': 'DSP',        'name': 'Durgapur Steel Plant',        'state': 'West Bengal',  'kind': 'Plant'},
    {'code': 'RSP',        'name': 'Rourkela Steel Plant',        'state': 'Odisha',       'kind': 'Plant'},
    {'code': 'BSL',        'name': 'Bokaro Steel Plant',          'state': 'Jharkhand',    'kind': 'Plant'},
    {'code': 'ISP',        'name': 'IISCO Steel Plant Burnpur',   'state': 'West Bengal',  'kind': 'Plant'},
    {'code': 'ASP',        'name': 'Alloy Steels Plant',          'state': 'West Bengal',  'kind': 'Plant'},
    {'code': 'SSP',        'name': 'Salem Steel Plant',           'state': 'Tamil Nadu',   'kind': 'Plant'},
    {'code': 'CFP',        'name': 'Chandrapur Ferro Alloys',     'state': 'Maharashtra',  'kind': 'Plant'},
    {'code': 'CMO',        'name': 'Central Marketing Org',       'state': 'Delhi',        'kind': 'Marketing'},
    {'code': 'JGOM',       'name': 'Jharkhand Group of Mines',    'state': 'Jharkhand',    'kind': 'Mines'},
    {'code': 'OGOM',       'name': 'Odisha Group of Mines',       'state': 'Odisha',       'kind': 'Mines'},
    {'code': 'BSP_MINES',  'name': 'BSP Mines',                   'state': 'Chhattisgarh', 'kind': 'Mines'},
    {'code': 'COLLIERIES', 'name': 'Collieries Division',         'state': 'Jharkhand/WB', 'kind': 'Mines'},
    {'code': 'SRU',        'name': 'SRU Kulti',                   'state': 'West Bengal',  'kind': 'Refractory'},
    {'code': 'SSO',        'name': 'SSO Ranchi',                     'state': 'Jharkhand',    'kind': 'Safety'},
    {'code': 'OTHER',      'name': 'Others',                      'state': '—',            'kind': 'Other'},
  ];

  static String stateForPlant(String plantNameOrCode) {
    final q = plantNameOrCode.trim().toUpperCase();
    for (final p in sailPlants) {
      if (q == p['code']!.toUpperCase() ||
          q == p['name']!.toUpperCase() ||
          p['name']!.toUpperCase().contains(q)) {
        return p['state']!;
      }
    }
    return '—';
  }

  // ── PLANT NAME CANONICALIZATION ──────────────────────────────────
  // Incidents were captured over time with the plant field in many
  // formats — "DSP", "DSP Durgapur", "Durgapur Steel Plant",
  // "DSP — Durgapur Steel Plant", plus en-dash/em-dash variants. This
  // maps any of them to ONE canonical "CODE — Name" label so analytics
  // group correctly and dropdowns show each plant only once.
  //
  // Matching (against the ACTIVE list, so admin edits are respected):
  //   1. exact code, exact name, or exact "code — name"
  //   2. code appears as a standalone token in the raw string
  //   3. every significant word of a plant name appears in the raw string
  // Falls back to the cleaned original when there is no confident match.

  /// Hardcoded mappings for common variations that should map to canonical names
  static const Map<String, String> plantNameMappings = {
    'SSO RANCHI': 'SSO Ranchi',
    'SSO — RANCHI': 'SSO Ranchi',
    'CORPORATE RANCHI': 'SSO Ranchi',
    'CORP RANCHI': 'SSO Ranchi',
    'CORPORATE — RANCHI': 'SSO Ranchi',
    'CORP — RANCHI': 'SSO Ranchi',
    'CORPORATE-RANCHI': 'SSO Ranchi',
    'CO-DELHI': 'Corporate Office-Delhi',
    'SAIL SAFETY ORGANISATION': 'SSO Ranchi',
    'SAIL SAFETY ORGANIZATION': 'SSO Ranchi',
  };

  static String canonicalPlantFrom(
      String raw, List<Map<String, String>> plants) {
    // Normalise dashes to a single spaced em-dash and collapse whitespace.
    final cleaned = raw
        .replaceAll(RegExp(r'[‒–—―-]'), '—')
        .replaceAll(RegExp(r'\s*—\s*'), ' — ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';

    final upper = cleaned.toUpperCase();

    // Pass 0 — Check hardcoded mappings FIRST (for known problematic variations)
    if (plantNameMappings.containsKey(upper)) {
      return plantNameMappings[upper]!;
    }

    // Word set of the raw string for token matching.
    final rawWords = upper
        .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toSet();

    Map<String, String>? match;

    // Pass 1 — exact code / name / "code — name".
    for (final p in plants) {
      final code = (p['code'] ?? '').toUpperCase();
      final name = (p['name'] ?? '').toUpperCase();
      final full = '$code — $name';
      if (upper == code || upper == name || upper == full) { match = p; break; }
    }

    // Pass 2 — code present as a standalone token (e.g. "DSP Durgapur").
    if (match == null) {
      for (final p in plants) {
        final code = (p['code'] ?? '').toUpperCase();
        if (code.isNotEmpty && code != 'OTHER' && rawWords.contains(code)) {
          match = p; break;
        }
      }
    }

    // Pass 3 — all significant words of a plant name are present.
    if (match == null) {
      for (final p in plants) {
        final name = (p['name'] ?? '').toUpperCase();
        if (name.isEmpty || name == 'OTHERS') continue;
        final nameWords = name
            .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
            .split(' ')
            .where((w) => w.length > 2) // skip "of", "&", short glue words
            .toSet();
        if (nameWords.isNotEmpty && nameWords.every(rawWords.contains)) {
          match = p; break;
        }
      }
    }

    if (match != null) {
      final code = match['code'] ?? '';
      final name = match['name'] ?? '';
      // If the name already carries its own separator (e.g. "SSO Ranchi"),
      // don't prefix the code again — that would double the dash.
      if (name.contains('—')) return name;
      if (code.isNotEmpty && code != 'OTHER' && name.isNotEmpty) {
        return '$code — $name';
      }
      if (name.isNotEmpty) return name;
    }
    return cleaned; // no confident match — keep the cleaned original
  }

  /// Which entry of the ACTIVE plant list a raw plant string belongs to, or null
  /// when it cannot be resolved confidently.
  ///
  /// Deliberately NOT implemented as "canonicalPlantFrom(raw) == plantLabel(p)".
  /// [canonicalPlantFrom] checks [plantNameMappings] first and returns the bare
  /// mapped name, so 'SSO Ranchi' canonicalises to 'SSO Ranchi' while the code
  /// 'SSO' canonicalises to 'SSO — SSO Ranchi' — two different strings for one
  /// plant. Comparing labels would therefore fail for exactly the unit that
  /// matters most here. This resolves to the ENTRY instead, so callers can
  /// compare plants by code and never by spelling.
  ///
  /// Pass order matters: the exact name check runs before the code-token check
  /// so 'BSP Mines' resolves to BSP Mines and not to Bhilai Steel Plant.
  static Map<String, String>? plantEntryFor(
      String raw, List<Map<String, String>> plants) {
    final cleaned = raw
        .replaceAll(RegExp(r'[‒–—―-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toUpperCase();
    if (cleaned.isEmpty) return null;

    final words = cleaned
        .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .toSet();

    for (final p in plants) {
      final code = (p['code'] ?? '').toUpperCase();
      final name = (p['name'] ?? '').toUpperCase();
      if (cleaned == code || cleaned == name) return p;
    }
    for (final p in plants) {
      final code = (p['code'] ?? '').toUpperCase();
      if (code.isNotEmpty && code != 'OTHER' && words.contains(code)) return p;
    }
    for (final p in plants) {
      final name = (p['name'] ?? '').toUpperCase();
      if (name.isEmpty || name == 'OTHERS') continue;
      final nameWords = name
          .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
          .split(' ')
          .where((w) => w.length > 2)
          .toSet();
      if (nameWords.isNotEmpty && nameWords.every(words.contains)) return p;
    }
    return null;
  }

  /// Strings that identify a plant inside the `app_users.plant` and
  /// `app_users.unit` columns, for use as ILIKE terms. Both the code and the
  /// full name, because the roster has been written both ways over time.
  static List<String> plantMatchTerms(Map<String, String> p) {
    final out = <String>[];
    final code = (p['code'] ?? '').trim();
    final name = (p['name'] ?? '').trim();
    if (code.isNotEmpty && code.toUpperCase() != 'OTHER') out.add(code);
    if (name.isNotEmpty && name.toUpperCase() != 'OTHERS') out.add(name);
    return out;
  }

  /// The ONE canonical display label for a plant entry: "CODE — Name"
  /// (or just the name when it already carries its own separator, e.g.
  /// "SSO Ranchi", or when there is no useful code).
  /// Every dropdown must use this so labels never diverge between screens.
  static String plantLabel(Map<String, String> p) {
    final code = (p['code'] ?? '').trim();
    final name = (p['name'] ?? '').trim();
    if (name.isEmpty) return code;
    if (name.contains('—')) return name;
    if (code.isEmpty || code == 'OTHER') return name;
    return '$code — $name';
  }

  /// Display labels for the active plant list, de-duplicated and order-preserved.
  static Future<List<String>> getPlantLabels() async {
    final plants = await getPlants();
    final out = <String>[];
    for (final p in plants) {
      final label = plantLabel(p);
      if (label.isNotEmpty && !out.contains(label)) out.add(label);
    }
    return out;
  }

  /// Convenience: canonicalize using the current active plant list.
  static Future<String> canonicalPlant(String raw) async {
    if (raw.trim().isEmpty) return '';
    final plants = await getPlants();
    return canonicalPlantFrom(raw, plants);
  }

  // ── DEFAULT WSA 13 CAUSES ────────────────────────────────────────
  static const List<String> defaultWsaCauses = [
    '1. Failure to follow procedure',
    '2. Lack of hazard awareness',
    '3. Improper PPE use',
    '4. Unsafe body positioning',
    '5. Equipment failure',
    '6. Communication failure',
    '7. Human error',
    '8. Poor housekeeping',
    '9. Lack of supervision',
    '10. Fatigue / time pressure',
    '11. Unauthorized operation',
    '12. Inadequate isolation (LOTO/PTW)',
    '13. Environmental conditions',
  ];

  // ── DEFAULT DEPARTMENTS ──────────────────────────────────────────
  static const List<String> defaultDepartments = [
    'Blast Furnace', 'Steel Melting Shop', 'Coke Ovens',
    'Sinter Plant', 'Rolling Mill', 'Hot Strip Mill',
    'Cold Rolling Mill', 'Plate Mill', 'Bar & Rod Mill',
    'Wire Rod Mill', 'Power Plant', 'Oxygen Plant',
    'Refractory', 'Mechanical Maintenance',
    'Electrical Maintenance', 'Instrumentation',
    'Civil', 'Stores', 'Transport', 'Mines',
    'Quality Assurance', 'Safety', 'Fire Brigade',
    'Medical', 'Security', 'Personnel', 'Finance',
    'IT', 'Training', 'Environment',
  ];

  // ── DEFAULT SEVERITIES ───────────────────────────────────────────
  static const List<String> defaultSeverities = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];

  // ── DEFAULT STATUSES ─────────────────────────────────────────────
  static const List<String> defaultStatuses = [
    'OPEN', 'INVESTIGATING', 'ACTION TAKEN', 'VERIFIED', 'CLOSED',
  ];

  /// Statuses that mean "the case is finished". Screens must not hardcode
  /// `status == 'OPEN' || ... 'INVESTIGATING' || ... 'ACTION TAKEN'`, because
  /// adding one stage in the admin panel would then make it invisible to
  /// every "open cases" count. Use [openStatusesFrom] instead.
  ///
  /// ★ FIX: This is now only used as a fallback. The primary logic is:
  ///   - The LAST status in the admin's list is always terminal.
  ///   - Any status the admin removed from their list is treated as terminal
  ///     (to prevent stale statuses from counting as "open").
  static const List<String> _defaultTerminalStatuses = ['VERIFIED', 'CLOSED'];

  /// Everything in [statuses] that isn't terminal, upper-cased for comparison.
  /// ★ FIX: Only the LAST status in the admin's ladder is terminal.
  /// This means admin can add/rename statuses without hardcoded assumptions.
  static Set<String> openStatusesFrom(List<String> statuses) {
    if (statuses.isEmpty) return {};
    final last = statuses.last.trim().toUpperCase();
    return statuses
        .map((s) => s.trim().toUpperCase())
        .where((s) => s != last)
        .toSet();
  }

  /// Convenience async form for callers that don't already hold the list.
  static Future<Set<String>> getOpenStatuses() async =>
      openStatusesFrom(await getStatuses());

  /// True if [status] means "finished". The last configured status is always
  /// terminal by definition — that's the end of the admin's ladder.
  /// ★ FIX: Removed hardcoded terminalStatuses check. Only the last status
  /// in the admin's list is terminal. If admin renames or removes a status,
  /// it's no longer terminal.
  static Future<bool> isTerminalStatus(String status) async {
    final s = status.trim().toUpperCase();
    if (s.isEmpty) return false;
    final all = await getStatuses();
    if (all.isEmpty) return false;
    final last = all.last.trim().toUpperCase();
    return s == last;
  }

  /// The status a newly created record starts in — the first rung of the
  /// admin's ladder, not a hardcoded 'OPEN'. Returns '' if the admin has
  /// deleted every status, since an empty list is a legitimate configuration
  /// and inventing a value would contradict the admin panel.
  static Future<String> firstStatus() async {
    final all = await getStatuses();
    return all.isEmpty ? '' : all.first;
  }

  /// The status that closes a record — the last rung of the admin's ladder.
  /// '' if no statuses are configured.
  static Future<String> lastStatus() async {
    final all = await getStatuses();
    return all.isEmpty ? '' : all.last;
  }

  // ── DEFAULT OBSERVATION TYPES ────────────────────────────────────
  static const List<String> defaultObservationTypes = [
    'Unsafe Act', 'Unsafe Condition', 'Near Miss', 'First Aid Case',
  ];

  // ── STORAGE KEYS for custom (user-edited) lists ──────────────────
  static const String _kPlants     = 'admin_master_plants';
  static const String _kDepts      = 'admin_master_departments';
  static const String _kWsa        = 'admin_master_wsa_causes';
  static const String _kSeverities = 'admin_master_severities';
  static const String _kStatuses   = 'admin_master_statuses';
  static const String _kObsTypes   = 'admin_master_obs_types';

  // ── READ helpers — fall back to defaults if not customised ───────
  static Future<List<Map<String, String>>> getPlants() async {
    final prefs = await SharedPreferences.getInstance();
    final raw   = prefs.getString(_kPlants);
    if (raw == null) {
      return sailPlants.map((p) => Map<String, String>.from(p)).toList();
    }
    try {
      final l = (jsonDecode(raw) as List)
          .map((e) => Map<String, String>.from(
              (e as Map).map((k, v) => MapEntry(k.toString(), v.toString()))))
          .toList();
      return l;
    } catch (_) {
      return sailPlants.map((p) => Map<String, String>.from(p)).toList();
    }
  }

  static Future<List<String>> _getList(String key, List<String> def) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return List<String>.from(def);
    try {
      final l = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      return l;
    } catch (_) {
      return List<String>.from(def);
    }
  }

  static Future<List<String>> getDepartments() => _getList(_kDepts, defaultDepartments);
  static Future<List<String>> getWsaCauses()   => _getList(_kWsa, defaultWsaCauses);
  static Future<List<String>> getSeverities()  => _getList(_kSeverities, defaultSeverities);
  static Future<List<String>> getStatuses()    => _getList(_kStatuses, defaultStatuses);
  static Future<List<String>> getObsTypes()    => _getList(_kObsTypes, defaultObservationTypes);

  // ── SAVE helpers (local + push to backend) ──────────────────────
  static Future<void> savePlants(List<Map<String, String>> v, {bool syncToBackend = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPlants, jsonEncode(v));
    _bump();
    if (syncToBackend) {
      _pushWithRetry(() => SyncService.pushMasterData(plants: v), 'plants',
          'pushMasterData', {'plants': v});
    }
  }

  static Future<void> _saveList(String key, List<String> v, {bool syncToBackend = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(v));
    _bump();
    if (syncToBackend) {
      // Push the specific list to backend with retry on failure
      switch (key) {
        case _kDepts:
          _pushWithRetry(() => SyncService.pushMasterData(departments: v),
              'departments', 'pushMasterData', {'departments': v});
          break;
        case _kWsa:
          _pushWithRetry(() => SyncService.pushMasterData(wsaCauses: v),
              'near-miss causes', 'pushMasterData', {'wsaCauses': v});
          break;
        case _kSeverities:
          _pushWithRetry(() => SyncService.pushMasterData(severities: v),
              'severities', 'pushMasterData', {'severities': v});
          break;
        case _kStatuses:
          _pushWithRetry(() => SyncService.pushMasterData(statuses: v),
              'statuses', 'pushMasterData', {'statuses': v});
          break;
        case _kObsTypes:
          _pushWithRetry(() => SyncService.pushMasterData(obsTypes: v),
              'observation types', 'pushMasterData', {'obsTypes': v});
          break;
      }
    }
  }

  static Future<void> saveDepartments(List<String> v, {bool syncToBackend = true}) =>
      _saveList(_kDepts, v, syncToBackend: syncToBackend);
  static Future<void> saveWsaCauses(List<String> v, {bool syncToBackend = true}) =>
      _saveList(_kWsa, v, syncToBackend: syncToBackend);
  static Future<void> saveSeverities(List<String> v, {bool syncToBackend = true}) =>
      _saveList(_kSeverities, v, syncToBackend: syncToBackend);
  static Future<void> saveStatuses(List<String> v, {bool syncToBackend = true}) =>
      _saveList(_kStatuses, v, syncToBackend: syncToBackend);
  static Future<void> saveObsTypes(List<String> v, {bool syncToBackend = true}) =>
      _saveList(_kObsTypes, v, syncToBackend: syncToBackend);

  // ── PULL from backend & update local storage ───────────────────
  /// Call on app startup to fetch latest master data from server.
  /// Returns true if data was updated from server.
  static Future<bool> syncFromBackend() async {
    try {
      final remote = await SyncService.pullMasterData();
      if (remote == null || remote.isEmpty) return false;

      bool updated = false;

      // The admin panel is AUTHORITATIVE. A key that is PRESENT but holds an
      // empty list means the admin deleted every entry — that must propagate,
      // otherwise deletions silently never take effect and the frontend
      // deviates from the admin panel. A key that is ABSENT means the server
      // simply has no opinion, so the local list is left alone.
      if (remote['plants'] is List) {
        final plants = (remote['plants'] as List)
            .map((e) => Map<String, String>.from(
                (e as Map).map((k, v) => MapEntry(k.toString(), v.toString()))))
            .toList();
        await savePlants(plants, syncToBackend: false);
        updated = true;
      }
      if (remote['departments'] is List) {
        final depts = (remote['departments'] as List).map((e) => e.toString()).toList();
        await saveDepartments(depts, syncToBackend: false);
        updated = true;
      }
      if (remote['wsaCauses'] is List) {
        final wsa = (remote['wsaCauses'] as List).map((e) => e.toString()).toList();
        await saveWsaCauses(wsa, syncToBackend: false);
        updated = true;
      }
      if (remote['severities'] is List) {
        final sev = (remote['severities'] as List).map((e) => e.toString()).toList();
        await saveSeverities(sev, syncToBackend: false);
        updated = true;
      }
      if (remote['statuses'] is List) {
        final st = (remote['statuses'] as List).map((e) => e.toString()).toList();
        await saveStatuses(st, syncToBackend: false);
        updated = true;
      }
      if (remote['obsTypes'] is List) {
        final obs = (remote['obsTypes'] as List).map((e) => e.toString()).toList();
        await saveObsTypes(obs, syncToBackend: false);
        updated = true;
      }

      // ★ FIX: Pull SPI params from backend
      if (remote['spiParams'] is Map) {
        final spi = (remote['spiParams'] as Map)
            .map((k, v) => MapEntry(k.toString(), (v is int) ? v : int.tryParse(v.toString()) ?? 0));
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kSpiParams, jsonEncode(spi));
        updated = true;
      }

      // ★ FIX: Pull SPI card visibility from backend
      if (remote['spiCardVisible'] != null) {
        final visible = remote['spiCardVisible'] == true ||
            remote['spiCardVisible'] == 'true';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kShowSpiCard, visible);
        updated = true;
      }

      // Pull SOP-scan-tab release state from backend.
      //
      // This is how a non-admin device learns the feature was released: the
      // admin toggles on their device, it lands in master_data, and every other
      // device picks it up on its next pull. So the snapshot MUST be written
      // here too — this is the one path that changes the flag on a device that
      // never called setSopScanTabVisible, and without it the pref would be
      // right while the nav bar kept reading a stale snapshot until restart.
      if (remote['sopScanTabVisible'] != null) {
        final visible = remote['sopScanTabVisible'] == true ||
            remote['sopScanTabVisible'] == 'true';
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kShowSopScanTab, visible);
        _sopScanTabSnapshot = visible;
        updated = true;
      }

      // ★ FIX: Pull severity scores from backend
      if (remote['severityScores'] is Map) {
        var scores = (remote['severityScores'] as Map)
            .map((k, v) => MapEntry(k.toString(), (v is int) ? v : int.tryParse(v.toString()) ?? 0));
        final prefs = await SharedPreferences.getInstance();
        // Rebase HERE as well as in getSeverityScores, and push the correction
        // back — judged by RANGE (_isOutOfRangeScale), so a near-miss of the old
        // numbers is caught too, not only an exact 25/15/10/5 match.
        // Without this the pull is a way for the old 5–25 scale to return
        // permanently: the backend row still holds it, the local one-shot rebase
        // flag has already been spent, so every launch would re-import the legacy
        // numbers and nothing would ever correct them again. Rebasing at the
        // point of import — and writing the result back so other devices and the
        // next pull agree — closes that loop.
        if (_isOutOfRangeScale(scores)) {
          scores = _normaliseScale(scores);
          await prefs.setBool(_kScoresRebased, true);
          _pushWithRetry(() => SyncService.pushMasterData(severityScores: scores),
              'severity scores (rebased)', 'pushMasterData',
              {'severityScores': scores});
        }
        await prefs.setString(_kSeverityScores, jsonEncode(scores));
        // This pull runs on EVERY launch and overwrites whatever the admin saved
        // locally. If an admin edit did not reach the backend, this is the line
        // that quietly undoes it — so it must be visible in the console.
        print('$_kScoreTag backend pull overwrote the local scale with $scores');
        updated = true;
      }

      // ★ v25: Sync ALL API keys from backend — ensures all devices have keys
      // Keys come from Script Properties (permanent) so they survive app redeployments
      final prefs = await SharedPreferences.getInstance();
      if (remote['geminiApiKey'] is String && (remote['geminiApiKey'] as String).length > 10) {
        await prefs.setString('gemini_vision_api_key', remote['geminiApiKey'] as String);
        updated = true;
      }
      if (remote['groqApiKey'] is String && (remote['groqApiKey'] as String).length > 10) {
        await prefs.setString('groq_api_key', remote['groqApiKey'] as String);
        updated = true;
      }
      if (remote['openRouterApiKey'] is String && (remote['openRouterApiKey'] as String).length > 10) {
        await prefs.setString(GeminiVision.kOpenRouterKey1, remote['openRouterApiKey'] as String);
        updated = true;
      }
      // Optional SECOND OpenRouter key (failover). Absent from older backend
      // records, so a missing field must leave any locally-set key alone rather
      // than clearing it — hence no `else` branch here.
      if (remote['openRouterApiKey2'] is String && (remote['openRouterApiKey2'] as String).length > 10) {
        await prefs.setString(GeminiVision.kOpenRouterKey2, remote['openRouterApiKey2'] as String);
        updated = true;
      }
      // NaraRouter (Tier 1b). Prefix-checked, not just length-checked: this
      // sync runs on EVERY launch, so a wrong-provider key sitting in the
      // backend record would be re-written to every device forever and add a
      // dead 20s attempt to failing scans. A missing field deliberately has no
      // `else` branch — see the second OpenRouter key above for why.
      if (remote['naraApiKey'] is String &&
          (remote['naraApiKey'] as String).startsWith(NaraVision.keyPrefix)) {
        await prefs.setString(
            NaraVision.kPrefsApiKey, remote['naraApiKey'] as String);
        updated = true;
      }
      // The admin's MODEL choice, validated the same way geminiModel is below.
      // Validation matters here because a REJECTED value falls back to
      // NaraVision.defaultModel rather than failing loudly, so a typo'd slug
      // silently runs a different model than the admin chose — which breaks
      // latency attribution in the AI Performance dashboard.
      //
      // The list is also the app's only guard against a model that is not on the
      // account's Nara plan: those return HTTP 402 and take the whole tier down
      // (this happened on 2026-08-19 with mimo-v2.5-free, since removed). So
      // keeping availableModels honest is a correctness matter, not cosmetics.
      if (remote['naraModel'] is String &&
          (remote['naraModel'] as String).isNotEmpty) {
        final remoteNaraModel = remote['naraModel'] as String;
        if (NaraVision.availableModels.any((m) => m['id'] == remoteNaraModel)) {
          await prefs.setString(NaraVision.kPrefsModel, remoteNaraModel);
          updated = true;
        }
      }
      if (remote['geminiModel'] is String && (remote['geminiModel'] as String).isNotEmpty) {
        // Validate before writing. This sync runs on every launch, so an old
        // backend record holding a model Google has since retired would
        // otherwise re-poison the pref after GeminiDirectVision.getModel() had
        // already migrated it — the scan would 404 again on every cold start.
        // Only accept IDs the app actually offers; ignore anything else and
        // leave the locally-migrated value in place.
        final remoteModel = remote['geminiModel'] as String;
        final isKnown = GeminiDirectVision.availableModels
            .any((m) => m['id'] == remoteModel);
        if (isKnown) {
          await prefs.setString('gemini_vision_model', remoteModel);
          updated = true;
        }
      }

      return updated;
    } catch (_) {
      return false;
    }
  }

  // ── APP SETTINGS (admin-configurable) ──────────────────────────────
  static const String _kShowSpiCard = 'admin_show_spi_card';
  static const String _kSpiParams = 'admin_spi_params';
  static const String _kShowSopScanTab = 'admin_show_sop_scan_tab';

  /// Default SPI calculation parameters
  static const Map<String, int> defaultSpiParams = {
    'closureMaxPoints': 60,      // Max points for closure rate component
    'staleMaxPoints': 25,        // Max points for stale incidents component
    'criticalMaxPoints': 15,     // Max points for critical incidents component
    'stalePenalty': 5,           // Points deducted per stale incident (>7 days)
    'criticalPenalty': 1,        // Points deducted per critical incident
  };

  /// Get whether SPI scorecard should be shown in frontend Reports
  static Future<bool> getSpiCardVisible() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getBool(_kShowSpiCard);
      // If never set, default to FALSE (hidden) for safety
      // Admin must explicitly enable it
      return value ?? false;
    } catch (e) {
      print('Error reading SPI visibility: $e');
      return false; // Fail-safe: hide by default
    }
  }

  /// Set SPI scorecard visibility
  static Future<void> setSpiCardVisible(bool visible) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowSpiCard, visible);
      await prefs.reload(); // Force reload to ensure persistence
      _bump();
      // ★ FIX: Push to backend with retry so other devices see the visibility toggle
      _pushWithRetry(() => SyncService.pushMasterData(spiCardVisible: visible),
          'SPI visibility', 'pushMasterData', {'spiCardVisible': visible});
      // Verify it was saved
      final saved = prefs.getBool(_kShowSpiCard);
      if (saved != visible) {
        print('WARNING: SPI visibility not saved correctly! Expected $visible, got $saved');
      }
    } catch (e) {
      print('Error saving SPI visibility: $e');
    }
  }

  /// Whether the SOP/SMP Scan tab has been released to normal users.
  ///
  /// Defaults to FALSE, and the default is the point of the setting: the feature
  /// went in unproven, and shipping the client with it visible would put an
  /// untested reader in front of every user on the next deploy. Admins see the
  /// tab whether this is true or false, so the admin can exercise it in
  /// production against real documents before anyone else gets it.
  ///
  /// Read this async form when you can await. The bottom nav cannot, and uses
  /// [sopScanTabVisibleSync].
  static Future<bool> getSopScanTabVisible() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kShowSopScanTab) ?? false;
    } catch (e) {
      print('Error reading SOP scan tab visibility: $e');
      return false; // Fail-safe: hidden by default.
    }
  }

  /// Release (or withdraw) the SOP/SMP Scan tab for normal users.
  ///
  /// Withdrawing works as well as releasing: if the feature misbehaves in the
  /// field this is the way back, and it takes effect on other devices at their
  /// next pull without a new build.
  static Future<void> setSopScanTabVisible(bool visible) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowSopScanTab, visible);
      await prefs.reload();
      // Write through to the synchronous snapshot BEFORE bumping, so the
      // listeners that _bump() wakes read the new value rather than the old one.
      // The reverse order is a real bug, not a style point: home_screen rebuilds
      // from the revision listener and would paint the previous state.
      _sopScanTabSnapshot = visible;
      _bump();
      _pushWithRetry(
          () => SyncService.pushMasterData(sopScanTabVisible: visible),
          'SOP scan tab visibility',
          'pushMasterData',
          {'sopScanTabVisible': visible});
      final saved = prefs.getBool(_kShowSopScanTab);
      if (saved != visible) {
        print('WARNING: SOP scan tab visibility not saved! '
            'Expected $visible, got $saved');
      }
    } catch (e) {
      print('Error saving SOP scan tab visibility: $e');
    }
  }

  /// Get SPI calculation parameters
  static Future<Map<String, int>> getSpiParams() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSpiParams);
    if (raw == null) return Map<String, int>.from(defaultSpiParams);
    try {
      final map = (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k.toString(), (v is int) ? v : int.tryParse(v.toString()) ?? 0));
      return map;
    } catch (_) {
      return Map<String, int>.from(defaultSpiParams);
    }
  }

  /// Set SPI calculation parameters
  static Future<void> setSpiParams(Map<String, int> params) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSpiParams, jsonEncode(params));
    _bump();
    // ★ FIX: Push to backend with retry so other devices get the updated SPI formula
    _pushWithRetry(() => SyncService.pushMasterData(spiParams: params),
        'SPI parameters', 'pushMasterData', {'spiParams': params});
  }

  // ── PLANT NAME DATA MIGRATION ──────────────────────────────────────
  /// Normalize all incident plant names to canonical names from admin panel.
  /// This is a one-time migration that should be run when fixing historical data.
  /// Returns a map with normalization statistics.
  ///
  /// NOTE: This method is defined in AdminMasterData but must be called from
  /// admin_screen.dart where LocalDB is available to avoid circular imports.

  // ── SEVERITY SCORING (admin-configurable) ─────────────────────────
  static const String _kSeverityScores = 'admin_severity_scores';

  /// Set once the stored 5–25 scale has been rebased onto 0–100. See
  /// [_legacySeverityScores].
  static const String _kScoresRebased = 'admin_severity_scores_rebased_v2';

  /// Default scale, on the 0–100 range that every screen displays.
  ///
  /// These used to be 25/15/10/5, which was wrong in a way nobody noticed for a
  /// long time: the admin editor clamps to 0–100, the AI scan card renders
  /// "$score/100", the offline analyser emits 72–88, and the PDF prints the same
  /// number. So a CRITICAL near-miss was filed at "25/100" and read as mild,
  /// sitting in the same list as an AI scan of a lesser hazard showing 72. The
  /// numbers were never on the same scale and the lower one was the real one.
  static const Map<String, int> defaultSeverityScores = {
    'CRITICAL': 90,
    'HIGH': 70,
    'MEDIUM': 45,
    'LOW': 20,
  };

  /// The old 5–25 scale, kept ONLY so a stored copy of it can be recognised and
  /// replaced. A reset, or a master-data pull from a device that had reset,
  /// wrote these numbers into SharedPreferences and into the backend, so plenty
  /// of installs hold them without any admin having chosen them. Recognised by
  /// exact match on all four values, so a deliberate scale that happens to be
  /// low is left exactly as the admin set it.
  static const Map<String, int> _legacySeverityScores = {
    'CRITICAL': 25,
    'HIGH': 15,
    'MEDIUM': 10,
    'LOW': 5,
  };

  static bool _isLegacyScale(Map<String, int> m) {
    if (m.length != _legacySeverityScores.length) return false;
    for (final e in _legacySeverityScores.entries) {
      if (m[e.key] != e.value) return false;
    }
    return true;
  }

  /// The lowest credible top-of-scale for a number rendered as "N / 100".
  ///
  /// Nothing in the app displays a risk score except against 100 — the scan card,
  /// the near-miss form and the PDF all print "/100". A scale whose worst level is
  /// below this is therefore not "a low scale an admin chose", it is a scale on the
  /// wrong RANGE, and it makes the app contradict itself in print: a CRITICAL
  /// finding came out as "23 / 100" on a real exported report.
  static const int _kMinTopOfScale = 30;

  static int _topOf(Map<String, int> m) =>
      m.values.fold<int>(0, (a, b) => b > a ? b : a);

  /// Whether [m] is on a range the app cannot display honestly.
  ///
  /// **Why a shape test rather than an exact match:** [_isLegacyScale] only
  /// recognised 25/15/10/5 exactly, so any variant of the old range — an admin who
  /// nudged HIGH to 16, a partially-synced row, a backend record from a device that
  /// had reset — sailed straight through and kept printing single-digit "/100"
  /// scores. Judging the range instead of the exact values catches all of them.
  static bool _isOutOfRangeScale(Map<String, int> m) {
    final top = _topOf(m);
    return top > 0 && top <= _kMinTopOfScale;
  }

  /// Lift an out-of-range scale onto 0–100 while keeping the admin's ordering.
  ///
  /// The exact legacy map is replaced by the app defaults, since that is what it
  /// was meant to be. Anything else is scaled proportionally so that its worst
  /// level lands on the default CRITICAL score: an admin who set 25/18/9/3 clearly
  /// meant HIGH to sit well above MEDIUM, and flattening them all onto the defaults
  /// would throw that judgement away. Zero and negative entries are left alone —
  /// they are a deliberate "does not count", not a mis-scaled value.
  static Map<String, int> _normaliseScale(Map<String, int> m) {
    if (!_isOutOfRangeScale(m)) return m;
    if (_isLegacyScale(m)) return Map<String, int>.from(defaultSeverityScores);
    final factor = defaultSeverityScores['CRITICAL']! / _topOf(m);
    return m.map((k, v) =>
        MapEntry(k, v <= 0 ? v : (v * factor).round().clamp(1, 100)));
  }

  /// Diagnostic tag for the console. The score that reaches a scan card comes
  /// through four hands — the stored pref, the backend pull, the legacy rebase,
  /// and the per-label lookup — and when the number on screen matches none of
  /// the numbers in the admin panel, the only way to tell WHICH hand changed it
  /// is to see the map at the moment it is read. Cheap, and worth keeping.
  static const String _kScoreTag = '[SeverityScores]';

  static Future<Map<String, int>> getSeverityScores() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSeverityScores);
    if (raw == null) {
      print('$_kScoreTag no stored scale — using defaults '
          '$defaultSeverityScores');
      return Map<String, int>.from(defaultSeverityScores);
    }
    try {
      final map = (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k.toString(), (v is int) ? v : int.tryParse(v.toString()) ?? 0));
      // Correct an out-of-range scale on EVERY read, not once.
      //
      // This used to be a one-shot migration guarded by _kScoresRebased. That flag
      // was the hole: once it was spent, any later write of a low scale — a backend
      // master-data pull, a restore, a hand-edited row — stuck permanently, and the
      // app went back to printing "23 / 100" beside "RISK: CRITICAL". The flag is
      // still set (other code reads it) but it no longer gates the correction: a
      // score that cannot be displayed honestly is fixed every time it is loaded,
      // and the fix is written back so the next read is a no-op rather than a
      // repeated rewrite.
      if (_isOutOfRangeScale(map)) {
        final rebased = _withCanonicalLevels(_normaliseScale(map));
        await prefs.setBool(_kScoresRebased, true);
        await prefs.setString(_kSeverityScores, jsonEncode(rebased));
        // Tell the screens. Anything that loaded the old map before this read —
        // the near-miss form, the AI scan card — is holding 25/15/10/5 and will
        // keep displaying it until something bumps the revision. Bumping from
        // inside a getter is unusual, but the alternative is a one-off wrong
        // number on a safety report.
        _bump();
        print('$_kScoreTag stored scale $map could not be shown against /100 '
            '(top value ${_topOf(map)}) — rebased to $rebased');
        return rebased;
      }
      print('$_kScoreTag loaded $map '
          '(rebase flag=${prefs.getBool(_kScoresRebased) ?? false})');
      return _withCanonicalLevels(map);
    } catch (e) {
      print('$_kScoreTag stored scale could not be parsed ($e) — using '
          'defaults. Raw value was: $raw');
      return Map<String, int>.from(defaultSeverityScores);
    }
  }

  /// Guarantees the four canonical levels are present, without touching any
  /// value the admin actually set.
  ///
  /// A stored scale can arrive with a level missing — a partial row in the
  /// backend, a hand-edited record, a save made while the level list was being
  /// changed. When that happened the lookup for the missing level fell through
  /// to MEDIUM, so a CRITICAL hazard was scored as a moderate one. That is a
  /// safety defect, not a cosmetic one: it under-reports the worst finding on
  /// the report, and it does so silently. Filling the gap from the defaults
  /// keeps CRITICAL above HIGH above MEDIUM above LOW no matter how damaged the
  /// stored record is, and the gap is logged so the underlying cause is still
  /// visible rather than papered over.
  ///
  /// Extra levels the admin invented are preserved untouched — this only adds
  /// what is missing.
  static Map<String, int> _withCanonicalLevels(Map<String, int> stored) {
    final missing = defaultSeverityScores.keys
        .where((k) => !stored.containsKey(k))
        .toList(growable: false);
    if (missing.isEmpty) return stored;
    final filled = Map<String, int>.from(defaultSeverityScores)..addAll(stored);
    print('$_kScoreTag stored scale was MISSING $missing — filled from '
        'defaults, giving $filled. A missing level would otherwise be scored as '
        'MEDIUM, which under-rates the worst finding on the report.');
    return filled;
  }

  static Future<void> saveSeverityScores(Map<String, int> scores) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSeverityScores, jsonEncode(scores));
    _bump();
    // ★ FIX: Push to backend with retry so other devices get the updated risk scores
    _pushWithRetry(() => SyncService.pushMasterData(severityScores: scores),
        'severity scores', 'pushMasterData', {'severityScores': scores});
  }

  /// The 0–100 band each canonical severity label may be displayed in.
  ///
  /// Inclusive, worst-first, abutting with no gaps so every score maps to exactly
  /// one label. Not admin-editable: this is the invariant that stops a report
  /// contradicting itself, not a tuning knob.
  static const Map<String, ({int min, int max})> severityBands = {
    'CRITICAL': (min: 80, max: 100),
    'HIGH': (min: 60, max: 79),
    'MEDIUM': (min: 35, max: 59),
    'LOW': (min: 5, max: 34),
  };

  /// A risk score guaranteed not to contradict the severity label shown next to it.
  ///
  /// **Why:** an exported report printed "RISK: CRITICAL" and, fourteen lines
  /// below, "23 / 100". Both numbers were computed honestly — the label is the
  /// worst hazard's severity, the score comes from the stored scale — but that
  /// device's scale was still on the old 5–25 range, so on paper the document
  /// argued with itself. The reader either dismisses a critical finding or stops
  /// trusting the report. [_isOutOfRangeScale] repairs the scale going forward;
  /// this repairs what is ALREADY stored, and what arrives from Apps Script,
  /// at the last point before display.
  ///
  /// **How to apply:** the LABEL wins, always — it is derived from the hazard rows
  /// the reader is acting on. The score is raised to the band floor if it was too
  /// low and capped at the ceiling if it was too high ("LOW" printing 95/100 is
  /// the same defect mirrored), and returned untouched when it already agrees,
  /// which is the normal case. An unrecognised label is left alone rather than
  /// guessed at.
  static int scoreForDisplay(String severity, dynamic score) {
    final raw =
        (score is int ? score : int.tryParse('$score') ?? 0).clamp(0, 100);
    final band = severityBands[severity.trim().toUpperCase()];
    if (band == null) return raw;
    if (raw >= band.min && raw <= band.max) return raw;
    final fixed = raw < band.min ? band.min : band.max;
    // Loud on purpose: this firing means something upstream is on the wrong
    // scale, and the display is only papering over it at the last moment.
    print('$_kScoreTag score $raw contradicts severity $severity — shown as '
        '$fixed to keep the report self-consistent');
    return fixed;
  }

  /// Risk score for a severity label, using the admin-configured scale.
  /// Single source of truth — callers must not hardcode their own scale.
  static Future<int> scoreForSeverity(String severity) async {
    final scores = await getSeverityScores();
    return scoreFromMap(scores, severity);
  }

  /// Synchronous form, for callers that already hold the map.
  ///
  /// Screens that render a score on every frame must not await SharedPreferences
  /// in `build`. They load the map once, refresh it on [revision], and call this.
  ///
  /// Fallback order for a label the stored scale does not contain: the app's own
  /// [defaultSeverityScores] entry for THAT label, then MEDIUM, then 45 — never
  /// 0. An unrecognised severity usually means the admin renamed or removed a
  /// level, and scoring a real hazard 0 because of a rename would file it as
  /// harmless.
  static int scoreFromMap(Map<String, int> scores, String severity) {
    final key = severity.trim().toUpperCase();
    final exact = scores[key];
    if (exact != null) return exact;

    // A miss is the single most likely cause of "the number on the scan matches
    // nothing in the admin panel", so say so — once per label, because this runs
    // inside build() and a per-frame print would bury the rest of the console.
    //
    // The fallback order matters, and getting it wrong is how a report ended up
    // showing a CRITICAL hazard beside a risk score of 23/100. If the stored
    // scale is missing or incomplete, EVERY label — CRITICAL included —
    // collapsed to the MEDIUM value, and the only trace was this console line,
    // which no safety officer ever sees. So: try the built-in score for THIS
    // label first. A CRITICAL finding is still worth 90 when an admin scale is
    // incomplete; only a label that is genuinely unknown to the app falls back
    // to the middle of the scale.
    final builtIn = defaultSeverityScores[key];
    if (_warnedKeys.add(key)) {
      print('$_kScoreTag NO ENTRY for "$key" — the stored scale has keys '
          '${scores.keys.toList()}. Falling back to '
          '${builtIn != null ? "the built-in $key score ($builtIn)" : "MEDIUM"}.');
    }
    if (builtIn != null) return builtIn;
    return scores['MEDIUM'] ?? defaultSeverityScores['MEDIUM']!;
  }

  static final Set<String> _warnedKeys = <String>{};

  /// Overall score for a set of severity labels: the worst level wins.
  ///
  /// Deliberately NOT a sum or an average of the hazards found. The admin panel
  /// says "the score value for each severity level", so a scan whose worst
  /// finding is HIGH must show exactly the number the admin typed against HIGH —
  /// predictable, auditable, and the same on two scans that found the same worst
  /// thing. Hazard count is already shown next to it and does not need to be
  /// smuggled into the risk number.
  static int worstScore(Map<String, int> scores, Iterable<String> severities) {
    int best = -1;
    for (final s in severities) {
      if (s.trim().isEmpty) continue;
      final v = scoreFromMap(scores, s);
      if (v > best) best = v;
    }
    return best < 0 ? 0 : best;
  }

  /// Points added for each hazard beyond the most serious one.
  ///
  /// Small on purpose. See [combinedScore] for why it cannot simply be tuned up.
  static const int kExtraHazardPoints = 4;

  /// Overall score for a report: the worst finding, escalated for the others.
  ///
  /// [worstScore] alone gave the same number to a photo with one HIGH hazard and
  /// a photo with one HIGH plus four more — which reads as though the extra
  /// findings did not count. This adds [kExtraHazardPoints] per additional
  /// hazard on top of the worst one.
  ///
  /// The escalation is CAPPED so that it can never carry a report past the next
  /// severity level up. That guarantee is the whole design: a stack of LOW
  /// findings must never outscore a single CRITICAL one, because the moment it
  /// can, the number stops meaning "how bad is the worst thing here" and a wall
  /// of trivia can bury a genuine danger. So the ceiling is taken from the
  /// admin's own scale at runtime — the smallest score above the base — rather
  /// than from a hardcoded assumption about what the levels are worth. When the
  /// worst finding is already at the top of the scale the remaining headroom to
  /// 100 is used instead.
  ///
  /// Consequences worth knowing before changing this: the admin's number is now
  /// the FLOOR for a severity, not the exact value, and several findings at the
  /// top level will saturate near 100. Both are stated in the admin help text.
  static int combinedScore(Map<String, int> scores, Iterable<String> severities) {
    final labels =
        severities.where((s) => s.trim().isNotEmpty).toList(growable: false);
    if (labels.isEmpty) return 0;

    final base = worstScore(scores, labels);
    final extras = labels.length - 1;
    if (extras <= 0) return base;

    // Lowest score in the scale that still sits above the base. 101 means the
    // base is already the highest level the admin defined.
    int nextLevel = 101;
    for (final v in scores.values) {
      if (v > base && v < nextLevel) nextLevel = v;
    }
    final headroom = (nextLevel - 1 - base).clamp(0, 100);
    final bump = (extras * kExtraHazardPoints).clamp(0, headroom);
    return (base + bump).clamp(0, 100);
  }

  // ── RESET to defaults ────────────────────────────────────────────
  /// Clears local overrides AND pushes the defaults to the backend, so a
  /// reset is not silently undone by the next startup pull.
  static Future<void> resetAllToDefaults({bool syncToBackend = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPlants);
    await prefs.remove(_kDepts);
    await prefs.remove(_kWsa);
    await prefs.remove(_kSeverities);
    await prefs.remove(_kStatuses);
    await prefs.remove(_kObsTypes);
    await prefs.remove(_kSeverityScores);
    await prefs.remove(_kSpiParams);
    await prefs.setBool(_kShowSpiCard, false);
    // Reset withdraws the SOP tab as well. "Reset to defaults" that left an
    // unreleased feature switched on would be the one direction of this button
    // that is not safe.
    await prefs.setBool(_kShowSopScanTab, false);
    _sopScanTabSnapshot = false;
    _bump();
    if (syncToBackend) {
      final resetPayload = <String, dynamic>{
        'plants': sailPlants.map((p) => Map<String, String>.from(p)).toList(),
        'departments': List<String>.from(defaultDepartments),
        'wsaCauses': List<String>.from(defaultWsaCauses),
        'severities': List<String>.from(defaultSeverities),
        'statuses': List<String>.from(defaultStatuses),
        'obsTypes': List<String>.from(defaultObservationTypes),
        'spiParams': Map<String, int>.from(defaultSpiParams),
        'spiCardVisible': false,
        'sopScanTabVisible': false,
        'severityScores': Map<String, int>.from(defaultSeverityScores),
      };
      _pushWithRetry(
        () => SyncService.pushMasterData(
          plants: sailPlants.map((p) => Map<String, String>.from(p)).toList(),
          departments: List<String>.from(defaultDepartments),
          wsaCauses: List<String>.from(defaultWsaCauses),
          severities: List<String>.from(defaultSeverities),
          statuses: List<String>.from(defaultStatuses),
          obsTypes: List<String>.from(defaultObservationTypes),
          spiParams: Map<String, int>.from(defaultSpiParams),
          spiCardVisible: false,
          sopScanTabVisible: false,
          severityScores: Map<String, int>.from(defaultSeverityScores),
        ),
        'reset to defaults',
        'pushMasterData',
        resetPayload,
      );
    }
  }
}
