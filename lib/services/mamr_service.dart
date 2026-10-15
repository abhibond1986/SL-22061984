// lib/services/mamr_service.dart
//
// MAMR — "My Area My Responsibility". Storage, sync, roles and user linking
// for the per-plant area-responsibility register. The pure parts (models,
// Excel cleaner, merge) are in mamr_core.dart so they can be tested on the
// plain Dart VM.
//
// STORAGE. One master_data row per plant, key `mamr_areas_<CODE>`, plus one
// row `mamr_sed` = { "<CODE>": ["username", …] } naming each plant's SED
// (Safety Engineering Department) users. Re-using master_data means the
// existing realtime channel (public:master_data → syncFromBackend) carries
// every SED edit to every device with no new table, no new policy and no
// new subscription.
//
// WHY THE SED LIST IS NOT A COLUMN ON app_users. SupabaseService.upsertUser
// has no unknown-column tolerance (upsertIncident does): adding `isSed` to
// _userAppToDb would make EVERY user write — registration, password change,
// the bulk import — fail on any project where the migration had not been
// run yet. A master_data row has no such failure mode.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_master_data.dart';
import 'assignment_inbox.dart';
import 'local_db.dart';
import 'mamr_core.dart';
import 'plant_scope.dart';
import 'supabase_config.dart';
import 'supabase_service.dart';

export 'mamr_core.dart';

class MamrService {
  const MamrService._();

  /// Bumped whenever a register or the SED list changes — local edit, pull,
  /// or realtime push. Screens listen and reload.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// "CODE|areaId" set by the Home card's Report button just before it
  /// switches to the MAMR tab; the tab adopts and clears it. A notifier, not
  /// a constructor argument, because the tab's State can already exist.
  static final ValueNotifier<String> pendingArea = ValueNotifier<String>('');

  static const String _kPrefix = 'mamr_areas_';
  static const String _kSedKey = 'mamr_sed';
  static const String _kPrefsReg = 'mamr_register_';
  static const String _kPrefsSed = 'mamr_sed_map';
  static const String _kPending = 'mamr_pending_push';

  static String remoteKeyFor(String code) =>
      '$_kPrefix${code.trim().toUpperCase()}';

  // ═══════════════════════════════════════════════════════════════════════
  //  PLANT CODES
  // ═══════════════════════════════════════════════════════════════════════

  /// Plant code for any spelling of a plant ('ASP ', 'Alloy Steels Plant',
  /// 'ASP — Alloy Steels Plant'), or '' when unknown.
  static Future<String> plantCodeOf(String raw) async {
    final plants = await AdminMasterData.getPlants();
    return (AdminMasterData.plantEntryFor(raw, plants)?['code'] ?? '')
        .toUpperCase();
  }

  /// Synchronous variant for the importer, given a loaded plant list.
  static String Function(String) plantCodeResolver(
          List<Map<String, String>> plants) =>
      (raw) => (AdminMasterData.plantEntryFor(raw, plants)?['code'] ?? '')
          .toUpperCase();

  /// The user's own plant code — `plant`, falling back to `unit` the same way
  /// AssignScope does for imported accounts with a blank plant.
  static Future<String> userPlantCode(Map<String, dynamic>? user) async {
    if (user == null) return '';
    final p = (user['plant']?.toString() ?? '').trim();
    if (p.isNotEmpty) {
      final c = await plantCodeOf(p);
      if (c.isNotEmpty) return c;
    }
    final u = (user['unit']?.toString() ?? '').trim();
    return u.isEmpty ? '' : await plantCodeOf(u);
  }

  /// "ASP — Alloy Steels Plant" for a code; the code itself when unknown.
  static Future<String> plantLabelFor(String code) async {
    final plants = await AdminMasterData.getPlants();
    final e = AdminMasterData.plantEntryFor(code, plants);
    return e == null ? code : AdminMasterData.plantLabel(e);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  REGISTER — read / write
  // ═══════════════════════════════════════════════════════════════════════

  static Future<MamrRegister> getRegister(String code) async {
    final c = code.trim().toUpperCase();
    if (c.isEmpty) return const MamrRegister(plant: '');
    final prefs = await SharedPreferences.getInstance();
    final reg = MamrRegister.tryDecode(prefs.getString('$_kPrefsReg$c'));
    return reg ?? MamrRegister(plant: c);
  }

  /// Every plant that has a register on this device.
  static Future<Map<String, MamrRegister>> getAllRegisters() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, MamrRegister>{};
    for (final k in prefs.getKeys()) {
      if (!k.startsWith(_kPrefsReg)) continue;
      final r = MamrRegister.tryDecode(prefs.getString(k));
      if (r != null && r.plant.isNotEmpty) out[r.plant] = r;
    }
    return out;
  }

  /// Save locally, then push. Returns true when the server has it; false
  /// means it is queued and will be re-sent by [flushPending] on the next
  /// sync, so the SED's work is never lost to a dropped connection.
  static Future<bool> saveRegister(MamrRegister reg) async {
    final c = reg.plant.trim().toUpperCase();
    if (c.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kPrefsReg$c', jsonEncode(reg.toJson()));
    revision.value++;
    return _push(remoteKeyFor(c), reg.toJson());
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SED role
  // ═══════════════════════════════════════════════════════════════════════

  static Future<Map<String, List<String>>> getSedMap() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeSed(prefs.getString(_kPrefsSed));
  }

  static Map<String, List<String>> _decodeSed(dynamic raw) {
    try {
      final v = raw is String ? jsonDecode(raw) : raw;
      if (v is! Map) return {};
      return v.map<String, List<String>>((k, l) => MapEntry<String, List<String>>(
            k.toString().toUpperCase(),
            ((l as List?) ?? const [])
                .map((e) => e.toString().trim().toLowerCase())
                .where((e) => e.isNotEmpty)
                .toSet()
                .toList(),
          ));
    } catch (_) {
      return {};
    }
  }

  static Future<bool> setSed(String code, String username, bool on) async {
    final c = code.trim().toUpperCase();
    final u = username.trim().toLowerCase();
    if (c.isEmpty || u.isEmpty) return false;
    final map = await getSedMap();
    final list = {...(map[c] ?? const <String>[])};
    on ? list.add(u) : list.remove(u);
    map[c] = list.toList()..sort();
    if (map[c]!.isEmpty) map.remove(c);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsSed, jsonEncode(map));
    revision.value++;
    return _push(_kSedKey, map);
  }

  /// Plant codes for which [user] is SED (usually one).
  static Future<List<String>> sedPlantsOf(Map<String, dynamic>? user) async {
    if (user == null) return const [];
    final ids = AssignmentInbox.identities(user);
    final map = await getSedMap();
    return [
      for (final e in map.entries)
        if (e.value.any(ids.contains)) e.key,
    ];
  }

  static Future<bool> isSed(Map<String, dynamic>? user) async =>
      (await sedPlantsOf(user)).isNotEmpty;

  /// Plants whose register [user] may edit. Super admin: every plant.
  /// SED: their SED plant(s). Anyone else: none.
  static Future<List<String>> manageablePlants(
      Map<String, dynamic>? user) async {
    if (user == null) return const [];
    if (PlantScope.isAdminUser(user)) {
      final plants = await AdminMasterData.getPlants();
      return plants
          .map((p) => (p['code'] ?? '').toUpperCase())
          .where((c) => c.isNotEmpty && c != 'OTHER')
          .toList();
    }
    return sedPlantsOf(user);
  }

  static Future<bool> canManage(Map<String, dynamic>? user, String code) async {
    if (user == null) return false;
    if (PlantScope.isAdminUser(user)) return true;
    return (await sedPlantsOf(user)).contains(code.trim().toUpperCase());
  }

  /// Plants this user may FILE an MAMR observation against. A plant user
  /// files for their own plant; admins and org-level users (SSO, contractors
  /// with no plant) choose among every plant that has a register.
  static Future<List<String>> fileablePlants(
      Map<String, dynamic>? user) async {
    final regs = await getAllRegisters();
    final withAreas = regs.values
        .where((r) => !r.isEmpty)
        .map((r) => r.plant)
        .toList()
      ..sort();
    if (user == null) return withAreas;
    final scope = await PlantScope.forUser(user);
    if (scope.seesAllPlants || (await userPlantCode(user)).isEmpty) {
      return withAreas;
    }
    final own = await userPlantCode(user);
    return [own];
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Observations — permissions
  // ═══════════════════════════════════════════════════════════════════════

  /// Who may mark an MAMR observation COMPLIED (move it to the last stage):
  /// the area's RESPONSIBLE PERSON — decided 2026-10-15. That is one of the
  /// people on the observation's responsible-person snapshot, or whoever it
  /// is currently assigned to (the SED may have reassigned it).
  ///
  /// The only exception is an observation filed against an area with nobody
  /// responsible at all: then the plant SED or the super admin may close it,
  /// because otherwise no one ever could.
  /// Intermediate stages keep the app's normal plant rule.
  static Future<bool> canMarkComplied(
      Map<String, dynamic>? user, Map<String, dynamic> inc) async {
    if (user == null) return false;
    if (!MamrObs.isMamr(inc)) return true;
    final ids = AssignmentInbox.identities(user);
    final assignee = inc['assignedTo']?.toString().trim().toLowerCase() ?? '';
    if (assignee.isNotEmpty && ids.contains(assignee)) return true;
    if (MamrObs.isResponsible(inc, ids, user['mobile']?.toString() ?? '')) {
      return true;
    }
    final nobody = MamrObs.responsible(inc).isEmpty && assignee.isEmpty;
    if (!nobody) return false;
    if (PlantScope.isAdminUser(user)) return true;
    final code = await plantCodeOf(inc['plant']?.toString() ?? '');
    return code.isNotEmpty && await canManage(user, code);
  }

  /// Who may assign / transfer an MAMR observation to someone else, beyond
  /// the normal same-plant rule: the person who REPORTED it (2026-10-15),
  /// any of its responsible persons, and the plant SED.
  static Future<bool> mayAssign(
      Map<String, dynamic>? user, Map<String, dynamic> inc) async {
    if (user == null || !MamrObs.isMamr(inc)) return false;
    if (PlantScope.isAdminUser(user)) return true;
    if (MamrObs.isReporter(user, inc)) return true;
    final ids = AssignmentInbox.identities(user);
    final assignee = inc['assignedTo']?.toString().trim().toLowerCase() ?? '';
    if (assignee.isNotEmpty && ids.contains(assignee)) return true;
    if (MamrObs.isResponsible(inc, ids, user['mobile']?.toString() ?? '')) {
      return true;
    }
    final code = await plantCodeOf(inc['plant']?.toString() ?? '');
    return code.isNotEmpty && await canManage(user, code);
  }

  /// Usernames that should see this observation in My Assignments.
  static Set<String> responsibleUsernames(Map<String, dynamic> inc) =>
      MamrObs.responsible(inc)
          .map((p) => p.username)
          .where((u) => u.isNotEmpty)
          .toSet();

  // ═══════════════════════════════════════════════════════════════════════
  //  Linking responsible persons to app accounts (by mobile)
  // ═══════════════════════════════════════════════════════════════════════

  /// Fill `username` for every responsible person who has a mobile but no
  /// link yet. Looks in Supabase first, then the device's cached roster.
  /// Existing links are never overwritten. Returns the updated register and
  /// the number of people newly linked.
  static Future<(MamrRegister, int)> linkByMobile(MamrRegister reg) async {
    final need = <String>{
      for (final a in reg.areas)
        for (final p in a.persons)
          if (!p.isLinked && p.mobile.isNotEmpty) p.mobile,
    };
    if (need.isEmpty) return (reg, 0);

    final found = <String, String>{}; // mobile → username
    try {
      if (SupabaseConfig.enabled) {
        final rows = await SupabaseService.findUsersByMobiles(need.toList());
        for (final u in rows) {
          final m = normaliseMobile(u['mobile']?.toString());
          final un = (u['username']?.toString() ?? '').trim().toLowerCase();
          if (m.isNotEmpty && un.isNotEmpty) found.putIfAbsent(m, () => un);
        }
      }
    } catch (_) {}
    if (found.length < need.length) {
      try {
        final local = await LocalDB.getAllUsers();
        for (final u in local) {
          final m = normaliseMobile(u['mobile']?.toString());
          final un = (u['username']?.toString() ?? '').trim().toLowerCase();
          if (need.contains(m) && un.isNotEmpty) found.putIfAbsent(m, () => un);
        }
      } catch (_) {}
    }
    if (found.isEmpty) return (reg, 0);

    var n = 0;
    final areas = reg.areas.map((a) {
      final persons = a.persons.map((p) {
        if (p.isLinked || !found.containsKey(p.mobile)) return p;
        n++;
        return p.copyWith(username: found[p.mobile]);
      }).toList();
      return a.copyWith(persons: persons);
    }).toList();
    return (reg.copyWith(areas: areas), n);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SYNC
  // ═══════════════════════════════════════════════════════════════════════

  static Future<bool> _push(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_kPending)?.toSet() ?? <String>{};
    var ok = false;
    if (SupabaseConfig.enabled) {
      try {
        ok = await SupabaseService.setMasterData(key, value);
      } catch (_) {
        ok = false;
      }
    }
    ok ? pending.remove(key) : pending.add(key);
    await prefs.setStringList(_kPending, pending.toList());
    return ok;
  }

  /// Re-send anything a failed push left queued. Called from the master-data
  /// pull, so it runs at start-up and on every realtime master_data event.
  static Future<void> flushPending() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_kPending) ?? const <String>[];
    for (final key in pending) {
      if (key == _kSedKey) {
        await _push(key, await getSedMap());
      } else if (key.startsWith(_kPrefix)) {
        final reg = await getRegister(key.substring(_kPrefix.length));
        await _push(key, reg.toJson());
      }
    }
  }

  /// Apply the server's `mamr_*` master_data rows. [raw] is
  /// { 'mamr_areas_ASP': {...}, 'mamr_sed': {...} } as fetched.
  ///
  /// The server is authoritative EXCEPT for a key this device still has
  /// queued: overwriting that would erase an SED's unsynced upload.
  static Future<void> applyRemote(Map<String, dynamic> raw) async {
    final prefs = await SharedPreferences.getInstance();
    await flushPending();
    final pending = prefs.getStringList(_kPending)?.toSet() ?? <String>{};
    var changed = false;
    for (final e in raw.entries) {
      if (pending.contains(e.key)) continue;
      if (e.key == _kSedKey) {
        final enc = jsonEncode(_decodeSed(e.value));
        if (prefs.getString(_kPrefsSed) != enc) {
          await prefs.setString(_kPrefsSed, enc);
          changed = true;
        }
      } else if (e.key.startsWith(_kPrefix)) {
        final reg = MamrRegister.tryDecode(e.value);
        if (reg == null) continue;
        final code = e.key.substring(_kPrefix.length).toUpperCase();
        final enc = jsonEncode(
            MamrRegister.fromJson({...reg.toJson(), 'plant': code}).toJson());
        if (prefs.getString('$_kPrefsReg$code') != enc) {
          await prefs.setString('$_kPrefsReg$code', enc);
          changed = true;
        }
      }
    }
    if (changed) revision.value++;
  }
}
