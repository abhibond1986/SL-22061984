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

  /// Warm the synchronous caches. Call once during app startup, and again
  /// whenever master data changes (the revision listener in main does this).
  static Future<void> primeSnapshots() async {
    try {
      _wsaSnapshot = await getWsaCauses();
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

      // ★ FIX: Pull severity scores from backend
      if (remote['severityScores'] is Map) {
        final scores = (remote['severityScores'] as Map)
            .map((k, v) => MapEntry(k.toString(), (v is int) ? v : int.tryParse(v.toString()) ?? 0));
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kSeverityScores, jsonEncode(scores));
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
      // This matters more here than it looks: NaraVision.defaultModel is
      // mistral-medium-3-5, the most expensive model on Nara's list, so a device
      // that receives the key but not the model would quietly spend the shared
      // token allowance several times faster than the one the admin chose.
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

  static const Map<String, int> defaultSeverityScores = {
    'CRITICAL': 25,
    'HIGH': 15,
    'MEDIUM': 10,
    'LOW': 5,
  };

  static Future<Map<String, int>> getSeverityScores() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSeverityScores);
    if (raw == null) return Map<String, int>.from(defaultSeverityScores);
    try {
      final map = (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k.toString(), (v is int) ? v : int.tryParse(v.toString()) ?? 0));
      return map;
    } catch (_) {
      return Map<String, int>.from(defaultSeverityScores);
    }
  }

  static Future<void> saveSeverityScores(Map<String, int> scores) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSeverityScores, jsonEncode(scores));
    _bump();
    // ★ FIX: Push to backend with retry so other devices get the updated risk scores
    _pushWithRetry(() => SyncService.pushMasterData(severityScores: scores),
        'severity scores', 'pushMasterData', {'severityScores': scores});
  }

  /// Risk score for a severity label, using the admin-configured scale.
  /// Single source of truth — callers must not hardcode their own scale.
  static Future<int> scoreForSeverity(String severity) async {
    final scores = await getSeverityScores();
    final key = severity.trim().toUpperCase();
    return scores[key] ?? scores['MEDIUM'] ?? 10;
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
          severityScores: Map<String, int>.from(defaultSeverityScores),
        ),
        'reset to defaults',
        'pushMasterData',
        resetPayload,
      );
    }
  }
}
