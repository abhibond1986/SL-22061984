// lib/services/local_db.dart
// SAIL Safety Lens — Local storage layer (SharedPreferences)
// ✅ All existing methods preserved
// ✅ NEW: seedKnowledgeBase() — loads 38 default FA 1948 + state-rules entries
// ✅ NEW: resetAllData()      — wipes incidents (optionally KB / users)
// ✅ NEW: dataCounts()        — counts for confirmation dialogs
// ✅ NEW (admin v5): upsertUser, deleteUser, replaceAllIncidents,
//                   replaceAllUsers, replaceAllKnowledgeDocs

import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';
import 'kb_seed_data.dart';
import 'crypto_utils.dart';
import 'admin_master_data.dart';

class LocalDB {
  static late SharedPreferences _prefs;
  static const _kUsers         = 'users';
  static const _kIncidents     = 'incidents';
  static const _kCurrentUser   = 'current_user';
  // ignore: unused_field
  static const _kKbTopics      = 'kb_topics';
  static const _kCachedUsers   = 'cached_users';
  static const _kKbDocs        = 'kb_documents';
  static const _kFeedback      = 'feedback_corrections';
  static const _kCustomHazards = 'custom_hazards';
  // AI correction records (user edits to AI output) queued locally. Kept even
  // when Supabase is the source of truth, so edits made offline are never lost
  // and so the admin panel still works if the backend is unreachable.
  static const _kAiCorrections = 'ai_corrections';
  // Tombstones: ids/usernames deleted locally that must stay hidden even if a
  // backend re-fetch still returns them (until the backend confirms removal).
  static const _kDeletedIncidentIds = 'deleted_incident_ids';
  static const _kDeletedUsernames   = 'deleted_usernames';

  // ═══════════════════════════════════════════════════════════════
  //  KNOWLEDGE BASE REVISION
  // ═══════════════════════════════════════════════════════════════
  /// Bumped whenever the knowledge base changes (doc added, edited, deleted,
  /// seeded or bulk-replaced by a sync).
  ///
  /// Why this exists: consumers of the KB cache it (the AI hazard analyser
  /// cached its KB context for the whole app session). Without a change signal
  /// a document the admin uploaded was ignored until the app was restarted —
  /// so "add knowledge, then scan" silently used the old knowledge. Listen to
  /// this and drop any derived cache.
  static final ValueNotifier<int> kbRevision = ValueNotifier<int>(0);

  /// Parsed-KB memo. [getKnowledgeDocs] used to `jsonDecode` the ENTIRE
  /// knowledge base on every call, and `searchKnowledge` calls it once per
  /// query — per chat message, per AI scan, per hazard analysis. That was
  /// tolerable with only the seeded entries; a single scanned SOP adds tens of
  /// entries and hundreds of KB of text, at which point the repeated full parse
  /// is the most expensive thing the app does on a keystroke.
  ///
  /// Invalidated in [_bumpKb] rather than at each write site on purpose: every
  /// mutation of `_kKbDocs` already calls `_bumpKb()` (verified across all eight
  /// write sites, including `remove` in `seedKnowledgeBase` and `resetAllData`),
  /// so hooking the bump cannot be forgotten by a future writer the way a
  /// per-site invalidation would be.
  static List<Map<String, dynamic>>? _kbCache;

  static void _bumpKb() {
    _kbCache = null;
    kbRevision.value++;
  }

  // ═══════════════════════════════════════════════════════════════
  //  TOMBSTONES — keep deletes from being resurrected by sheet merges
  // ═══════════════════════════════════════════════════════════════
  static Set<String> _readSet(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _writeSet(String key, Set<String> v) async {
    await _prefs.setString(key, jsonEncode(v.toList()));
  }

  static Set<String> deletedIncidentIds() => _readSet(_kDeletedIncidentIds);
  static Set<String> deletedUsernames()   => _readSet(_kDeletedUsernames);

  static Future<void> addDeletedIncidentId(String id) async {
    if (id.trim().isEmpty) return;
    final s = _readSet(_kDeletedIncidentIds)..add(id.trim());
    await _writeSet(_kDeletedIncidentIds, s);
  }

  /// Clear a single incident tombstone — used when a realtime INSERT/UPDATE
  /// arrives for an id that was previously deleted on this device, so the
  /// re-created record is allowed to surface again.
  static Future<void> removeDeletedIncidentId(String id) async {
    if (id.trim().isEmpty) return;
    final s = _readSet(_kDeletedIncidentIds);
    if (s.remove(id.trim())) await _writeSet(_kDeletedIncidentIds, s);
  }

  static Future<void> addDeletedUsername(String username) async {
    if (username.trim().isEmpty) return;
    final s = _readSet(_kDeletedUsernames)..add(username.trim());
    await _writeSet(_kDeletedUsernames, s);
  }

  /// Prune a tombstone once the backend confirms the record is gone
  /// (i.e. a fresh fetch no longer returns it).
  static Future<void> pruneIncidentTombstones(Set<String> stillPresentIds) async {
    final s = _readSet(_kDeletedIncidentIds);
    final pruned = s.where((id) => stillPresentIds.contains(id)).toSet();
    if (pruned.length != s.length) await _writeSet(_kDeletedIncidentIds, pruned);
  }

  static Future<void> pruneUsernameTombstones(Set<String> stillPresentUsernames) async {
    final s = _readSet(_kDeletedUsernames);
    final pruned = s.where((u) => stillPresentUsernames.contains(u)).toSet();
    if (pruned.length != s.length) await _writeSet(_kDeletedUsernames, pruned);
  }

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _seedIfEmpty();
  }

  static Future<void> _seedIfEmpty() async {
    if (_prefs.getString(_kUsers) == null) {
      // Seed users with hashed passwords (default password: 'demo')
      final seed = <Map<String, dynamic>>[];
      final seedData = [
        {'username': 'abhishek.kumar', 'name': 'Abhishek Kumar', 'designation': 'AGM',
         'plant': 'SSO Ranchi', 'pno': 'SAIL-SSO-001',
         'mobile': '9999999999', 'email': 'abhishek@sail.in', 'isAdmin': true},
        {'username': 'demo', 'name': 'R.K. Sharma', 'designation': 'Sr. Safety Officer',
         'plant': 'BSP Bhilai', 'pno': 'BSP-2024-001',
         'mobile': '9876543210', 'email': 'rks@sail.in', 'isAdmin': false},
        {'username': 'rajesh.kumar', 'name': 'Rajesh Kumar', 'designation': 'Safety Officer',
         'plant': 'BSP Bhilai', 'pno': 'BSP-2024-002',
         'mobile': '9876543211', 'email': 'rajesh@sail.in', 'isAdmin': false},
        {'username': 'priya.singh', 'name': 'Priya Singh', 'designation': 'Safety Supervisor',
         'plant': 'ISP Burnpur', 'pno': 'ISP-2024-001',
         'mobile': '9876543212', 'email': 'priya@sail.in', 'isAdmin': false},
      ];
      for (final u in seedData) {
        final salt = CryptoUtils.generateSalt();
        u['salt'] = salt;
        u['passwordHash'] = CryptoUtils.hashPassword('demo', salt);
        u['status'] = 'active';
        seed.add(u);
      }
      await _prefs.setString(_kUsers, jsonEncode(seed));
    }

    // NOTE: We intentionally DO NOT seed demo incidents. Previously, fixed-id
    // demo rows ('1'..'8') were created on every fresh install and then pushed
    // to the Google Sheet by fullSync — which refilled a sheet the admin had
    // cleared. Incidents are now sourced solely from the backend + real user
    // reports, so all devices show the same shared data.
    if (_prefs.getString(_kIncidents) == null) {
      await _prefs.setString(_kIncidents, jsonEncode(<Map<String, dynamic>>[]));
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  AUTH
  // ═══════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>?> signIn(
      String username, String password) async {
    // Check local users first
    final users = await getUsers();
    for (final u in users) {
      final uname  = u['username']?.toString() ?? '';
      final email  = u['email']?.toString() ?? '';
      if (uname != username && email != username) continue;

      // Block disabled users
      final status = (u['status']?.toString().toLowerCase() ?? 'active');
      if (status == 'disabled' || status == 'blocked') return null;

      // Try secure hash verification first
      final salt = u['salt']?.toString() ?? '';
      final storedHash = u['passwordHash']?.toString() ?? '';
      if (salt.isNotEmpty && storedHash.isNotEmpty) {
        if (CryptoUtils.verifyPassword(password, salt, storedHash)) {
          final safeUser = Map<String, dynamic>.from(u)
            ..remove('password')..remove('passwordHash')..remove('salt');
          await _prefs.setString(_kCurrentUser, jsonEncode(safeUser));
          return safeUser;
        }
      }

      // Legacy fallback: plaintext password (migrate on successful login)
      final stored = u['password']?.toString() ?? '';
      if (stored.isNotEmpty && stored == password) {
        // Migrate to hashed password
        await _migratePassword(u, password);
        final safeUser = Map<String, dynamic>.from(u)
          ..remove('password')..remove('passwordHash')..remove('salt');
        await _prefs.setString(_kCurrentUser, jsonEncode(safeUser));
        return safeUser;
      }

      // REMOVED — authentication bypass.
      //
      // This used to read:
      //     if (storedHash.isNotEmpty && salt.isEmpty && storedHash == password)
      //
      // i.e. it accepted the STORED HASH ITSELF as the password. Because
      // app_users is readable with the anon key, anyone who could read a row
      // could log in as that user by typing the hash. The legitimate legacy
      // case (an unsalted Apps Script hash) is now handled correctly in
      // AuthService._matchFormat, which compares against
      // legacySimpleHash(password) rather than against the raw input.
    }

    // Check cached users from backend
    final cached = await getAllUsers();
    for (final u in cached) {
      final uname = u['username']?.toString() ?? '';
      if (uname != username) continue;

      final status = (u['status']?.toString().toLowerCase() ?? 'active');
      if (status == 'disabled' || status == 'blocked') return null;

      final salt = u['salt']?.toString() ?? '';
      final storedHash = u['passwordHash']?.toString() ?? '';
      if (salt.isNotEmpty && storedHash.isNotEmpty) {
        if (CryptoUtils.verifyPassword(password, salt, storedHash)) {
          final safeUser = Map<String, dynamic>.from(u)
            ..remove('password')..remove('passwordHash')..remove('salt');
          await _prefs.setString(_kCurrentUser, jsonEncode(safeUser));
          return safeUser;
        }
      }
    }

    return null;
  }

  /// Migrate a legacy plaintext password to SHA-256 + salt
  static Future<void> _migratePassword(Map<String, dynamic> user, String password) async {
    final salt = CryptoUtils.generateSalt();
    final hash = CryptoUtils.hashPassword(password, salt);
    user['salt'] = salt;
    user['passwordHash'] = hash;
    user.remove('password'); // Remove plaintext

    // Update in users list
    final users = await getUsers();
    for (int i = 0; i < users.length; i++) {
      if (users[i]['username'] == user['username']) {
        users[i] = user;
        break;
      }
    }
    await _prefs.setString(_kUsers, jsonEncode(users));
  }

  static Future<Map<String, dynamic>?> register(
      Map<String, dynamic> userData) async {
    final users = await getUsers();
    if (users.any((u) => u['username'] == userData['username'])) {
      return null;
    }

    // Hash the password before storing
    final rawPassword = userData['password']?.toString() ?? '';
    if (rawPassword.isNotEmpty) {
      final salt = CryptoUtils.generateSalt();
      userData['salt'] = salt;
      userData['passwordHash'] = CryptoUtils.hashPassword(rawPassword, salt);
      userData.remove('password'); // Never store plaintext
    }

    users.add(userData);
    await _prefs.setString(_kUsers, jsonEncode(users));

    // If this username was previously deleted, clear its tombstone so the
    // re-registered account is visible again.
    final ts = _readSet(_kDeletedUsernames);
    final uname = (userData['username']?.toString() ?? '').trim();
    if (ts.remove(uname)) await _writeSet(_kDeletedUsernames, ts);

    // Store safe user (no credentials) in current session
    final safeUser = Map<String, dynamic>.from(userData)
      ..remove('password')..remove('passwordHash')..remove('salt');
    await _prefs.setString(_kCurrentUser, jsonEncode(safeUser));
    return safeUser;
  }

  /// Set a password locally. The new password is REQUIRED.
  ///
  /// It used to default to `newPassword = 'sail@123'`, and the "Forgot
  /// password?" dialog called it with no argument — so the reset flow set every
  /// account to a fixed string that is printed in the source code, on one
  /// device only. Callers must now say what the password is; the user-facing
  /// flows go through AuthService, which also writes it to Supabase.
  static Future<bool> resetPassword(String username, {required String newPassword}) async {
    if (newPassword.isEmpty) return false;
    // Read RAW so a tombstone-filtered write can't drop deleted records; the
    // old version wrote back the FILTERED list, permanently deleting every
    // tombstoned user as a side effect of a password reset.
    final raw = _prefs.getString(_kUsers);
    final users = raw == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)).toList();
    final target = username.trim().toLowerCase();
    bool found = false;
    for (int i = 0; i < users.length; i++) {
      if ((users[i]['username']?.toString() ?? '').trim().toLowerCase() == target ||
          (users[i]['email']?.toString() ?? '').trim().toLowerCase() == target) {
        final salt = CryptoUtils.generateSalt();
        users[i]['salt'] = salt;
        users[i]['passwordHash'] = CryptoUtils.hashPassword(newPassword, salt);
        users[i].remove('password'); // Remove any legacy plaintext
        found = true;
        break;
      }
    }
    if (found) {
      await _prefs.setString(_kUsers, jsonEncode(users));
    }
    return found;
  }

  /// Strip legacy plaintext credentials for a user from BOTH local buckets.
  ///
  /// Needed because upsertUser() MERGES — writing a fresh salt/passwordHash
  /// leaves any pre-existing `password` key untouched, and AuthService still
  /// honours plaintext for old admin-created accounts. Without this, changing
  /// a password left the old one working forever.
  static Future<void> clearLegacyPassword(String username) async {
    final target = username.trim().toLowerCase();
    if (target.isEmpty) return;

    Future<void> scrub(String key) async {
      final raw = _prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        var changed = false;
        for (final u in list) {
          final uname = (u['username']?.toString() ?? '').trim().toLowerCase();
          if (uname != target) continue;
          if (u.remove('password') != null) changed = true;
        }
        if (changed) await _prefs.setString(key, jsonEncode(list));
      } catch (_) {
        // Corrupt bucket — leave it alone rather than destroying it.
      }
    }

    await scrub(_kUsers);
    await scrub(_kCachedUsers);
  }

  static Future<void> signOut() async {
    await _prefs.remove(_kCurrentUser);
  }

  static Future<Map<String, dynamic>?> getCurrentUser() async {
    final raw = _prefs.getString(_kCurrentUser);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Set the current logged-in user (used after remote login)
  static Future<void> setCurrentUser(Map<String, dynamic> user) async {
    await _prefs.setString(_kCurrentUser, jsonEncode(user));
  }

  // ═══════════════════════════════════════════════════════════════
  //  USERS
  // ═══════════════════════════════════════════════════════════════

  static Future<List<Map<String, dynamic>>> getUsers() async {
    final raw = _prefs.getString(_kUsers);
    if (raw == null) return [];
    final tombstoned = deletedUsernames();
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .where((u) => !tombstoned.contains((u['username']?.toString() ?? '').trim()))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getAllUsers() async {
    final cached = await getCachedUsers();
    if (cached.isNotEmpty) return cached;
    return getUsers();
  }

  static Future<void> cacheUsers(
      List<Map<String, dynamic>> users) async {
    await _prefs.setString(_kCachedUsers, jsonEncode(users));
  }

  static Future<List<Map<String, dynamic>>> getCachedUsers() async {
    final raw = _prefs.getString(_kCachedUsers);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearCachedUsers() async {
    await _prefs.remove(_kCachedUsers);
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW (admin v5): UPSERT USER
  //  Insert or update a user record by `username`.
  //  Writes to the same `_kUsers` bucket that getUsers() reads.
  // ═══════════════════════════════════════════════════════════════
  static Future<void> upsertUser(Map<String, dynamic> user) async {
    final uname = (user['username']?.toString() ?? '').trim();
    if (uname.isEmpty) return;

    // Read RAW (not tombstone-filtered) so we update the real record rather
    // than duplicating a previously-deleted one.
    final rawU = _prefs.getString(_kUsers);
    final users = rawU == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(rawU) as List).map((e) => Map<String, dynamic>.from(e)).toList();
    final idx = users.indexWhere(
        (u) => (u['username']?.toString() ?? '').trim() == uname);

    if (idx >= 0) {
      // Merge: incoming non-empty values overwrite, others preserved
      final merged = Map<String, dynamic>.from(users[idx]);
      user.forEach((k, v) {
        if (v != null && v.toString().isNotEmpty) merged[k] = v;
      });
      users[idx] = merged;
    } else {
      users.add(Map<String, dynamic>.from(user));
    }
    await _prefs.setString(_kUsers, jsonEncode(users));

    // Re-adding a user clears any prior deletion tombstone.
    final ts = _readSet(_kDeletedUsernames);
    if (ts.remove(uname)) await _writeSet(_kDeletedUsernames, ts);

    // Also refresh cached_users so the dashboard switcher sees the change
    try {
      final cached = await getCachedUsers();
      if (cached.isNotEmpty) {
        final cIdx = cached.indexWhere(
            (u) => (u['username']?.toString() ?? '').trim() == uname);
        if (cIdx >= 0) {
          final merged = Map<String, dynamic>.from(cached[cIdx]);
          user.forEach((k, v) {
            if (v != null && v.toString().isNotEmpty) merged[k] = v;
          });
          cached[cIdx] = merged;
        } else {
          cached.add(Map<String, dynamic>.from(user));
        }
        await _prefs.setString(_kCachedUsers, jsonEncode(cached));
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW (admin v5): DELETE USER
  //  Removes a user (and cached copy) by username.
  // ═══════════════════════════════════════════════════════════════
  static Future<void> deleteUser(String username) async {
    final uname = username.trim();
    if (uname.isEmpty) return;

    // Read RAW (getUsers hides tombstoned) so we mutate the real bucket.
    final rawU = _prefs.getString(_kUsers);
    final users = rawU == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(rawU) as List).map((e) => Map<String, dynamic>.from(e)).toList();
    users.removeWhere(
        (u) => (u['username']?.toString() ?? '').trim() == uname);
    await _prefs.setString(_kUsers, jsonEncode(users));

    try {
      final cached = await getCachedUsers();
      if (cached.isNotEmpty) {
        cached.removeWhere(
            (u) => (u['username']?.toString() ?? '').trim() == uname);
        await _prefs.setString(_kCachedUsers, jsonEncode(cached));
      }
    } catch (_) {}

    // Tombstone so a backend re-fetch can't resurrect the deleted user.
    await addDeletedUsername(uname);
  }

  // ═══════════════════════════════════════════════════════════════
  //  INCIDENTS
  // ═══════════════════════════════════════════════════════════════

  static Future<List<Map<String, dynamic>>> getIncidents() async {
    final raw = _prefs.getString(_kIncidents);
    if (raw == null) return [];
    final tombstoned = deletedIncidentIds();
    final list = (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e))
        // Never surface a locally-deleted incident, even if it lingers.
        .where((i) => !tombstoned.contains(i['id']?.toString() ?? ''))
        .toList();
    list.sort((a, b) => (b['date'] ?? '')
        .toString()
        .compareTo((a['date'] ?? '').toString()));
    return list;
  }

  /// Write one incident, replacing any existing record with the same id.
  ///
  /// [stampUpdatedAt] must be false when the record came from the server —
  /// otherwise the incoming row gets marked with the local clock and
  /// [saveIncidentFromServer] would mistake it for an unsynced local edit on
  /// the next update, permanently pinning stale values.
  static Future<void> saveIncident(
      Map<String, dynamic> incident, {bool stampUpdatedAt = true}) async {
    final all  = await getIncidents();
    final user = await getCurrentUser();

    incident['id']            ??= DateTime.now().millisecondsSinceEpoch.toString();
    incident['date']          ??= DateTime.now().toIso8601String();
    incident['reportedBy']    ??= user?['name'] ?? 'Unknown';
    // 'reportedByPno' — NOT 'reporterPno'. This defaulted the wrong key, so
    // every reader (and the only server column, reported_by_pno) saw a blank
    // PNO whenever the creator hadn't set it explicitly.
    incident['reportedByPno'] ??= user?['pno'] ?? '';
    // First status comes from the admin's own ladder, not a hardcoded 'OPEN' —
    // if the admin renames the first status, new records must use the new name.
    incident['status']        ??= await AdminMasterData.firstStatus();

    // Normalize plant name to canonical name from admin panel
    if (incident['plant'] != null && incident['plant'].toString().isNotEmpty) {
      final plants = await AdminMasterData.getPlants();
      final canonical = AdminMasterData.canonicalPlantFrom(
          incident['plant'].toString(), plants);
      if (canonical.isNotEmpty) {
        incident['plant'] = canonical;
      }
    }

    // Stamp the local modification time so live sync can tell an incoming
    // server row apart from a newer unsynced local edit.
    //
    // Deliberately UTC. `DateTime.now().toIso8601String()` yields local time
    // with NO timezone offset, which a Postgres timestamptz column reads as
    // UTC — in IST that returns the value 5h30m in the past, so a genuinely
    // newer local edit compared as older and got overwritten. Writing UTC with
    // its trailing 'Z' makes the comparison correct whether the column is text
    // or timestamptz. DateTime.tryParse handles the 'Z' on read, and both sides
    // of the comparison in mergeServerIncident are then in the same frame.
    if (stampUpdatedAt) {
      incident['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    }

    // ✅ GPS Location fields (optional - may be null if GPS unavailable)
    // incident['latitude']        - GPS latitude
    // incident['longitude']       - GPS longitude
    // incident['locationAccuracy'] - GPS accuracy in meters
    // incident['locationAddress']  - Human-readable address
    // incident['locationTimestamp'] - When GPS was captured

    // Image retention:
    //  • Mobile stores the full image as a FILE (imageRef) — so we always
    //    strip the heavy imageBase64 from SharedPreferences here.
    //  • Web has no file storage, so the inline imageBase64 is the ONLY copy
    //    the PDF (with bbox overlays) can use. We keep it, but only for the
    //    most-recent few incidents to stay under the browser storage quota.
    final toStore = Map<String, dynamic>.from(incident);
    final hasFileRef = (toStore['imageRef']?.toString() ?? '').isNotEmpty;
    if (!kIsWeb || hasFileRef) {
      toStore.remove('imageBase64'); // mobile: file copy exists
    }

    final existingIdx = all.indexWhere(
        (i) => i['id']?.toString() == toStore['id']?.toString());
    if (existingIdx >= 0) {
      all[existingIdx] = toStore;
    } else {
      all.add(toStore);
    }

    // Bound inline-image storage: keep imageBase64 only on the newest
    // _kMaxInlineImages incidents; strip it from older ones to avoid quota.
    _boundInlineImages(all);

    try {
      await _prefs.setString(_kIncidents, jsonEncode(all));
    } catch (e) {
      // If still over quota (unlikely after stripping images), try removing
      // oldest incidents to make room
      if (e.toString().contains('QuotaExceeded')) {
        // Keep only last 50 incidents
        all.sort((a, b) => (b['date'] ?? '').toString()
            .compareTo((a['date'] ?? '').toString()));
        final trimmed = all.take(50).toList();
        await _prefs.setString(_kIncidents, jsonEncode(trimmed));
      } else {
        rethrow;
      }
    }
  }

  /// Max number of recent incidents allowed to keep a heavy inline
  /// imageBase64 (web only, where there's no file storage). Keeps the PDF
  /// image available for recent scans without blowing the browser quota.
  static const int _kMaxInlineImages = 8;

  /// Strip imageBase64 from all but the newest [_kMaxInlineImages] incidents.
  static void _boundInlineImages(List<Map<String, dynamic>> all) {
    // Sort a copy by date desc to find which ids are "recent".
    final sorted = List<Map<String, dynamic>>.from(all)
      ..sort((a, b) => (b['date'] ?? '').toString()
          .compareTo((a['date'] ?? '').toString()));
    final keepIds = sorted
        .take(_kMaxInlineImages)
        .map((i) => i['id']?.toString() ?? '')
        .toSet();
    for (final inc in all) {
      final id = inc['id']?.toString() ?? '';
      if (!keepIds.contains(id)) inc.remove('imageBase64');
    }
  }

  /// Permanently delete ALL incidents from local storage.
  /// Used by admin to clear all data and start fresh.
  /// WARNING: This cannot be undone!
  static Future<void> clearAllIncidents() async {
    await _prefs.setString(_kIncidents, jsonEncode([]));
    // Also clear the tombstone tracking
    await _prefs.remove(_kDeletedIncidentIds);
  }

  /// Apply an incident row that came FROM the server (realtime or a pull).
  ///
  /// Why this is not just [saveIncident]: saveIncident replaces the whole
  /// record. A server row legitimately lacks device-only fields (imageRef,
  /// imageBase64, thumbnailBase64) and, until the workflow columns existed,
  /// lacked the closure fields too — so every incoming UPDATE erased the
  /// corrective action and closure remarks the user had just typed but not yet
  /// synced. This merges instead:
  ///
  ///  • Device-only keys are always preserved (the server never has them).
  ///  • If the local copy is NEWER than the server copy (by `updatedAt`), the
  ///    local values win for the keys the server would otherwise blank out —
  ///    the pending push will reconcile them shortly.
  ///  • Otherwise the server value wins, which is what we want for a genuine
  ///    remote edit by another user.
  ///  • A key the server sends as null/empty never overwrites a non-empty
  ///    local value; that is data loss with no upside.
  static Future<void> saveIncidentFromServer(
      Map<String, dynamic> serverInc) async {
    final id = serverInc['id']?.toString() ?? '';
    if (id.isEmpty) return;

    final all = await getIncidents();
    final idx = all.indexWhere((i) => i['id']?.toString() == id);
    if (idx < 0) {
      // Brand-new to this device — nothing to preserve.
      await saveIncident(Map<String, dynamic>.from(serverInc),
          stampUpdatedAt: false);
      return;
    }

    await saveIncident(
        mergeServerIncident(local: all[idx], server: serverInc),
        stampUpdatedAt: false);
  }

  /// The single merge rule for "a server row met a local row of the same id".
  ///
  /// Pure and synchronous so the bulk-pull path in SyncService can apply the
  /// SAME rule without re-reading storage per record — two different merge
  /// rules is how one path ends up protecting an edit that the other discards.
  static Map<String, dynamic> mergeServerIncident({
    required Map<String, dynamic> local,
    required Map<String, dynamic> server,
  }) {
    final merged = Map<String, dynamic>.from(local);

    final localTs  = DateTime.tryParse(local['updatedAt']?.toString() ?? '');
    final serverTs = DateTime.tryParse(server['updatedAt']?.toString() ?? '');
    // Mixed frames are safe here: records written before the UTC change carry a
    // naive local-time string, which DateTime.tryParse flags as local, and
    // isAfter compares absolute epoch values — so a legacy naive value and a
    // new 'Z' value still compare correctly. Do not "normalise" these to UTC
    // after parsing; that would misread the legacy values.
    //
    // Treat local as newer only when we can actually prove it. If either row
    // carries no timestamp we can't compare, so we don't claim local wins —
    // except for keys the server omitted entirely, handled below.
    final localIsNewer =
        localTs != null && serverTs != null && localTs.isAfter(serverTs);

    bool blank(Object? v) => v == null || (v is String && v.trim().isEmpty);

    for (final entry in server.entries) {
      // A blank server value must never erase a real local one.
      if (blank(entry.value) && !blank(local[entry.key])) continue;
      if (localIsNewer &&
          _workflowKeys.contains(entry.key) &&
          !blank(local[entry.key])) {
        continue; // unsynced local edit wins until its push lands
      }
      merged[entry.key] = entry.value;
    }

    // Device-only fields: the server has no column for these, so an incoming
    // row must never be read as "the user cleared them".
    for (final k in _deviceOnlyKeys) {
      if (local.containsKey(k) && !server.containsKey(k)) merged[k] = local[k];
    }

    // Keep the local timestamp when local won, so the preserved edit stays
    // recognisable as local. Without this the server's older updatedAt would
    // overwrite the local one and the NEXT incoming row would win the
    // comparison, silently discarding the edit we just protected.
    if (localIsNewer) merged['updatedAt'] = local['updatedAt'];
    return merged;
  }

  /// Fields the user edits locally through the incident workflow. These are the
  /// ones worth protecting from a stale server row.
  static const Set<String> _workflowKeys = {
    'status', 'correctiveAction', 'rootCause', 'closedBy', 'closingRemarks',
    'closedAt', 'investigationStartedAt', 'actionTakenAt', 'assignedTo',
    'assignedAt', 'targetDate',
  };

  /// Fields that exist only on this device and have no server column.
  static const Set<String> _deviceOnlyKeys = {
    'imageRef', 'imageBase64', 'thumbnailBase64', 'shareImageBase64',
  };

  static Future<void> deleteIncident(String id) async {
    // Read the RAW list (getIncidents() already hides tombstoned ids).
    final raw = _prefs.getString(_kIncidents);
    final incidents = raw == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e)).toList();
    incidents.removeWhere((i) => i['id']?.toString() == id);
    await _prefs.setString(_kIncidents, jsonEncode(incidents));
    // Tombstone so a backend re-fetch can't resurrect it.
    await addDeletedIncidentId(id);
  }

  /// Server-authoritative reconciliation: drop every locally-stored incident
  /// whose id is NOT in [serverIds]. Used after the backend confirms its full
  /// set of incidents so a device can't keep showing rows that were deleted
  /// server-side (e.g. after an admin wipe).
  ///
  /// SAFETY: the caller MUST only pass a set fetched successfully from the
  /// server. Passing a stale/empty set due to a network error would wipe good
  /// local data — that's why the sync path uses [SupabaseService
  /// .fetchIncidentsOrNull] and skips reconcile when it returns null.
  ///
  /// Returns the number of local incidents removed.
  static Future<int> reconcileWithServer(Set<String> serverIds) async {
    final raw = _prefs.getString(_kIncidents);
    if (raw == null) return 0;
    final list = (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final before = list.length;
    list.removeWhere((i) => !serverIds.contains(i['id']?.toString() ?? ''));
    final removed = before - list.length;
    if (removed > 0) {
      await _prefs.setString(_kIncidents, jsonEncode(list));
    }
    return removed;
  }

  // ═══════════════════════════════════════════════════════════════
  //  ★ v35: UPDATE INCIDENT AUDIT DATA
  //  Merges audit fields (auditStatus, auditScore, etc.) into
  //  an existing incident record without touching other fields.
  // ═══════════════════════════════════════════════════════════════
  static Future<void> updateIncidentAudit(
      String id, Map<String, dynamic> auditData) async {
    final raw = _prefs.getString(_kIncidents);
    if (raw == null) return;
    final list = (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final idx = list.indexWhere((i) => i['id']?.toString() == id);
    if (idx < 0) return;

    // Merge audit fields
    for (final entry in auditData.entries) {
      list[idx][entry.key] = entry.value;
    }
    await _prefs.setString(_kIncidents, jsonEncode(list));
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW (admin v5): BULK REPLACE — used by Backup & Restore
  //  Wipes the bucket and writes the supplied list verbatim.
  // ═══════════════════════════════════════════════════════════════
  static Future<void> replaceAllIncidents(
      List<Map<String, dynamic>> incidents) async {
    // Strip imageBase64 to prevent storage quota overflow
    final cleaned = incidents.map((inc) {
      final copy = Map<String, dynamic>.from(inc);
      copy.remove('imageBase64');
      return copy;
    }).toList();
    await _prefs.setString(_kIncidents, jsonEncode(cleaned));
  }

  /// ✅ Purge bloated imageBase64 fields to reclaim storage quota.
  /// Mobile: strip ALL inline images (the full copy lives in file storage).
  /// Web: keep the newest few (only copy available for the PDF), strip the rest.
  /// Returns number of incidents cleaned.
  static Future<int> purgeStoredImages() async {
    final raw = _prefs.getString(_kIncidents);
    if (raw == null) return 0;

    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // On web, protect the newest _kMaxInlineImages so their PDF images survive.
      Set<String> keepIds = <String>{};
      if (kIsWeb) {
        final sorted = List<Map<String, dynamic>>.from(list)
          ..sort((a, b) => (b['date'] ?? '').toString()
              .compareTo((a['date'] ?? '').toString()));
        keepIds = sorted
            .take(_kMaxInlineImages)
            .map((i) => i['id']?.toString() ?? '')
            .toSet();
      }

      int cleaned = 0;
      for (final inc in list) {
        final id = inc['id']?.toString() ?? '';
        if (keepIds.contains(id)) continue; // web: keep recent inline image
        if (inc.containsKey('imageBase64') &&
            inc['imageBase64'] != null &&
            inc['imageBase64'].toString().length > 10) {
          inc.remove('imageBase64');
          cleaned++;
        }
      }
      if (cleaned > 0) {
        await _prefs.setString(_kIncidents, jsonEncode(list));
      }
      return cleaned;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> replaceAllUsers(
      List<Map<String, dynamic>> users) async {
    await _prefs.setString(_kUsers, jsonEncode(users));
  }

  static Future<void> replaceAllKnowledgeDocs(
      List<Map<String, dynamic>> docs) async {
    await _prefs.setString(_kKbDocs, jsonEncode(docs));
    _bumpKb();
  }

  // ═══════════════════════════════════════════════════════════════
  //  PLANT STATS
  // ═══════════════════════════════════════════════════════════════

  /// Per-plant rollup keyed by the canonical plant label.
  /// Plants come from AdminMasterData (the single source of truth) and
  /// incident plant strings are canonicalized before grouping, so the many
  /// historical formats ("DSP", "DSP Durgapur", "Durgapur Steel Plant") all
  /// roll up to one row. Previously this hardcoded five plants in a naming
  /// format ("BSP Bhilai") that matched neither the codes nor the canonical
  /// names, so every bucket read zero.
  static Future<Map<String, Map<String, int>>> getPlantStats() async {
    final inc = await getIncidents();
    final result = <String, Map<String, int>>{};
    final master = await AdminMasterData.getPlants();
    final labels = <String>[];
    for (final p in master) {
      final l = AdminMasterData.plantLabel(p);
      if (l.isNotEmpty && !labels.contains(l)) labels.add(l);
    }
    // Pre-canonicalize each incident once.
    final canon = inc
        .map((i) => AdminMasterData.canonicalPlantFrom(
            i['plant']?.toString() ?? '', master))
        .toList();
    // 'open' counts every non-terminal status from the admin's ladder. This
    // used to be `status == 'OPEN'` exactly, so INVESTIGATING and
    // ACTION TAKEN cases — genuinely open work — counted as zero, and a
    // renamed first status made the count zero altogether.
    final openStatuses = await AdminMasterData.getOpenStatuses();
    final firstStatus  = await AdminMasterData.firstStatus();
    final firstUpper   = firstStatus.trim().toUpperCase();
    bool isOpen(Map<String, dynamic> i) {
      var s = (i['status']?.toString().trim().toUpperCase() ?? '');
      if (s.isEmpty) s = firstUpper;
      return s.isNotEmpty && openStatuses.contains(s);
    }
    for (final p in labels) {
      final pInc = <Map<String, dynamic>>[];
      for (var k = 0; k < inc.length; k++) {
        if (canon[k] == p) pInc.add(inc[k]);
      }
      result[p] = {
        'total':    pInc.length,
        'open':     pInc.where(isOpen).length,
        'critical': pInc.where((i) => i['severity'] == 'CRITICAL').length,
        'high':     pInc.where((i) => i['severity'] == 'HIGH').length,
      };
    }
    return result;
  }

  static int calcSafetyScore(
      int critical, int high, int medium, int open) {
    return (100 - critical * 15 - high * 8 - medium * 3 - open * 2)
        .clamp(0, 100);
  }

  // ═══════════════════════════════════════════════════════════════
  //  FEEDBACK & LEARNING
  // ═══════════════════════════════════════════════════════════════

  static Future<void> saveFeedback({
    required int imageSeed,
    required String type,
    required Map<String, dynamic> hazardData,
  }) async {
    final all = await getAllFeedback();
    all.add({
      'imageSeed': imageSeed,
      'type':      type,
      'hazard':    hazardData,
      'timestamp': DateTime.now().toIso8601String(),
      'user':      (await getCurrentUser())?['name'] ?? 'unknown',
    });
    await _prefs.setString(_kFeedback, jsonEncode(all));
  }

  static Future<List<Map<String, dynamic>>> getAllFeedback() async {
    final raw = _prefs.getString(_kFeedback);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getFeedbackForSeed(
      int imageSeed) async {
    final all = await getAllFeedback();
    return all.where((f) => f['imageSeed'] == imageSeed).toList();
  }

  static Future<void> addCustomHazard(
      Map<String, dynamic> hazard) async {
    final all = await getCustomHazards();
    hazard['addedAt'] = DateTime.now().toIso8601String();
    hazard['addedBy'] = (await getCurrentUser())?['name'] ?? 'unknown';
    all.add(hazard);
    await _prefs.setString(_kCustomHazards, jsonEncode(all));
  }

  static Future<List<Map<String, dynamic>>> getCustomHazards() async {
    final raw = _prefs.getString(_kCustomHazards);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Future<void> clearFeedback() async {
    await _prefs.remove(_kFeedback);
    await _prefs.remove(_kCustomHazards);
  }

  static Future<Map<String, int>> getFeedbackStats() async {
    final all = await getAllFeedback();
    return {
      'total':    all.length,
      'added':    all.where((f) => f['type'] == 'add').length,
      'removed':  all.where((f) => f['type'] == 'remove').length,
      'reworded': all.where((f) => f['type'] == 'reword').length,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  //  KNOWLEDGE BASE
  // ═══════════════════════════════════════════════════════════════

  static Future<void> addKnowledgeDoc({
    required String title,
    required String content,
    String? source,
    // ── SOP/SMP scan metadata (all optional; absent for ordinary uploads) ──
    String? docGroup,
    String? sopNumber,
    String? clauseNo,
    int? pageFrom,
    int? pageTo,
    String? plant,
    bool verified = false,
    bool indexed = true,
  }) async {
    await addKnowledgeDocs([
      {
        'title':     title,
        'content':   content,
        'source':    source ?? 'uploaded',
        'docGroup':  docGroup,
        'sopNumber': sopNumber,
        'clauseNo':  clauseNo,
        'pageFrom':  pageFrom,
        'pageTo':    pageTo,
        'plant':     plant,
        'verified':  verified,
        'indexed':   indexed,
      }
    ]);
  }

  /// Bulk insert. Use this for anything that produces more than one entry —
  /// a scanned SOP is routinely 30–60 clause entries, and calling
  /// [addKnowledgeDoc] in a loop re-encodes and rewrites the WHOLE knowledge
  /// base once per entry (and bumps the revision each time, so every KB
  /// consumer drops its cache 60 times over). One encode, one write, one bump.
  ///
  /// Returns the ids assigned, in the order given, so the caller can push
  /// exactly these docs to the cloud instead of the entire KB.
  static Future<List<String>> addKnowledgeDocs(
      List<Map<String, dynamic>> docs) async {
    if (docs.isEmpty) return const [];
    final all      = await getKnowledgeDocs();
    final userName = (await getCurrentUser())?['name'] ?? 'admin';
    final stamp    = DateTime.now();
    final ids      = <String>[];

    for (int i = 0; i < docs.length; i++) {
      final d = docs[i];
      // Id must be unique across a single bulk call as well as across calls.
      // `millisecondsSinceEpoch` alone is not enough: a 60-entry loop can run
      // inside one millisecond, which is how the old `-${all.length}` suffix
      // was doing the real work. Keep an explicit index.
      final id = (d['id']?.toString().isNotEmpty ?? false)
          ? d['id'].toString()
          : '${stamp.millisecondsSinceEpoch}-${all.length + i}';
      ids.add(id);
      final row = <String, dynamic>{
        'id':         id,
        'title':      d['title']?.toString() ?? 'Untitled',
        'content':    d['content']?.toString() ?? '',
        'source':     d['source']?.toString() ?? 'uploaded',
        'uploadedAt': d['uploadedAt']?.toString() ?? stamp.toIso8601String(),
        'uploadedBy': d['uploadedBy']?.toString() ?? userName,
      };
      // Only carry optional keys when actually set, so ordinary uploads keep
      // producing the same compact rows they always did.
      for (final k in const [
        'docGroup', 'sopNumber', 'clauseNo', 'pageFrom', 'pageTo', 'plant'
      ]) {
        final v = d[k];
        if (v != null && v.toString().isNotEmpty) row[k] = v;
      }
      if (d['verified'] == true) row['verified'] = true;
      // `indexed` is written only when FALSE. Absent means indexed, which keeps
      // every pre-existing doc searchable without a data migration.
      if (d['indexed'] == false) row['indexed'] = false;
      all.add(row);
    }

    await _prefs.setString(_kKbDocs, jsonEncode(all));
    _bumpKb();
    return ids;
  }

  /// The docs matching [ids], in KB order. Used to push just-added docs to the
  /// cloud without shipping the entire knowledge base (which duplicated every
  /// existing row — see `SyncService.pushKbDocs`).
  static Future<List<Map<String, dynamic>>> knowledgeDocsByIds(
      List<String> ids) async {
    if (ids.isEmpty) return const [];
    final want = ids.toSet();
    return _kbDocsParsed()
        .where((d) => want.contains(d['id']?.toString()))
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// All docs belonging to one scanned document, in page/clause order.
  static Future<List<Map<String, dynamic>>> knowledgeDocsByGroup(
      String docGroup) async {
    if (docGroup.isEmpty) return const [];
    final rows = _kbDocsParsed()
        .where((d) => d['docGroup']?.toString() == docGroup)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    rows.sort((a, b) =>
        ((a['pageFrom'] as num?) ?? 0).compareTo((b['pageFrom'] as num?) ?? 0));
    return rows;
  }

  /// Deletes every entry of one scanned document (raw + all clause entries).
  /// Returns how many were removed.
  static Future<int> deleteKnowledgeGroup(String docGroup) async {
    if (docGroup.isEmpty) return 0;
    final all    = await getKnowledgeDocs();
    final before = all.length;
    all.removeWhere((d) => d['docGroup']?.toString() == docGroup);
    if (all.length == before) return 0;
    await _prefs.setString(_kKbDocs, jsonEncode(all));
    _bumpKb();
    return before - all.length;
  }

  /// Flips a whole scanned document to verified, promoting it into the
  /// authoritative block of the AI prompt. See
  /// `KnowledgeService.getContextForPrompt`.
  static Future<int> setKnowledgeGroupVerified(
      String docGroup, bool verified) async {
    if (docGroup.isEmpty) return 0;
    final all = await getKnowledgeDocs();
    int n = 0;
    for (final d in all) {
      if (d['docGroup']?.toString() == docGroup) {
        d['verified'] = verified;
        n++;
      }
    }
    if (n == 0) return 0;
    await _prefs.setString(_kKbDocs, jsonEncode(all));
    _bumpKb();
    return n;
  }

  /// Verify a SINGLE KB row by id.
  ///
  /// Exists for scans saved before `docGroup` did, where there is no group to
  /// match on. Prefer [setKnowledgeGroupVerified] for anything scanned since —
  /// verification is a decision about a document, not about one of its clauses.
  static Future<bool> setKnowledgeDocVerified(String id, bool verified) async {
    if (id.isEmpty) return false;
    final all = await getKnowledgeDocs();
    bool hit = false;
    for (final d in all) {
      if (d['id']?.toString() == id) {
        d['verified'] = verified;
        hit = true;
        break;
      }
    }
    if (!hit) return false;
    await _prefs.setString(_kKbDocs, jsonEncode(all));
    _bumpKb();
    return true;
  }

  /// Every KB doc. Callers may safely mutate what they get back — the maps are
  /// fresh copies, exactly as they were when this did a `jsonDecode` per call.
  /// The parse itself is now memoised; see [_kbCache].
  static Future<List<Map<String, dynamic>>> getKnowledgeDocs() async {
    final cached = _kbDocsParsed();
    return cached.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Read-only view of the parsed KB — no per-call copying. Only for code that
  /// exclusively READS (retrieval, stats, counting). Mutating anything returned
  /// here corrupts [_kbCache] without bumping the revision.
  static List<Map<String, dynamic>> _kbDocsParsed() {
    final cached = _kbCache;
    if (cached != null) return cached;
    final raw = _prefs.getString(_kKbDocs);
    if (raw == null || raw.isEmpty) return _kbCache = <Map<String, dynamic>>[];
    try {
      return _kbCache = (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      // Corrupt blob — behave like the old code did and report an empty KB
      // rather than throwing out of every AI call. Not cached, so a later
      // successful write can recover.
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> updateKnowledgeDoc({
    required String id,
    required String title,
    required String content,
    String? source,
  }) async {
    final all = await getKnowledgeDocs();
    final idx = all.indexWhere((d) => d['id'] == id);
    if (idx >= 0) {
      all[idx]['title']   = title;
      all[idx]['content'] = content;
      if (source != null) all[idx]['source'] = source;
      await _prefs.setString(_kKbDocs, jsonEncode(all));
      _bumpKb();
    }
  }

  static Future<void> deleteKnowledgeDoc(String id) async {
    final all = await getKnowledgeDocs();
    all.removeWhere((d) => d['id'] == id);
    await _prefs.setString(_kKbDocs, jsonEncode(all));
    _bumpKb();
  }

  /// ★ v30: Smart keyword search over the knowledge base, best match first.
  /// Now with synonym expansion, fuzzy matching, and phrase matching.
  ///
  /// [limit] caps how many documents come back.
  /// [snippetChars] caps each snippet.
  ///
  /// Entries carrying `indexed: false` are skipped. That flag exists for the
  /// raw full-text copy of a scanned SOP: scoring is by raw keyword hit COUNT,
  /// so one long unstructured OCR dump always outscores the tidy clause entries
  /// derived from it — same words, far more of them. Without this filter every
  /// SOP question would answer with a mid-sentence slice of raw OCR instead of
  /// the clause. The filter lives HERE, not at the call sites, because there
  /// are already five callers (chat_tab, KnowledgeService ×2, near_miss_tab,
  /// gemini_vision) and a sixth would forget.
  static Future<List<Map<String, dynamic>>> searchKnowledge(
      String query, {
      int limit = 3,
      int snippetChars = 400,
      }) async {
    final all =
        _kbDocsParsed().where((d) => d['indexed'] != false).toList();
    if (all.isEmpty) return [];
    // ★ lowered from 3 to 1 for short terms like "PPE", "LOTO"
    final q = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 1)
        .toSet()
        .toList();
    if (q.isEmpty) return [];

    // ★ Synonym expansion: map common safety terms to broader search terms
    final expanded = <String>{...q};
    for (final word in q) {
      final syns = _safetySynonyms[word];
      if (syns != null) expanded.addAll(syns);
    }

    final results = <Map<String, dynamic>>[];
    for (final doc in all) {
      final content      = doc['content']?.toString() ?? '';
      final title        = doc['title']?.toString() ?? '';
      final contentLower = content.toLowerCase();
      final titleLower   = title.toLowerCase();
      int score = 0;

      // ★ Exact word matches (original behavior)
      for (final word in q) {
        score += word.allMatches(contentLower).length;
        if (titleLower.contains(word)) score += 5;
      }

      // ★ Synonym matches (lower weight)
      for (final syn in expanded) {
        if (!q.contains(syn)) {
          score += (syn.allMatches(contentLower).length * 0.5).round();
          if (titleLower.contains(syn)) score += 2;
        }
      }

      // ★ Phrase matching: if query is 2+ words, check if full phrase appears
      if (q.length >= 2) {
        final phrase = q.join(' ');
        if (contentLower.contains(phrase)) score += 10;
      }

      // ★ Fuzzy matching: allow 1-char difference for words >= 4 chars
      for (final word in q) {
        if (word.length >= 4) {
          final fuzzy = _fuzzyVariants(word);
          for (final variant in fuzzy) {
            score += variant.allMatches(contentLower).length;
          }
        }
      }

      if (score > 0) {
        final sentences = content.split(RegExp(r'(?<=[.!?])\s+'));
        String bestSnippet      = '';
        int    bestSnippetScore = 0;
        for (final s in sentences) {
          final sl = s.toLowerCase();
          int ss = 0;
          for (final word in expanded) {
            if (sl.contains(word)) ss++;
          }
          if (ss > bestSnippetScore) {
            bestSnippetScore = ss;
            bestSnippet      = s.trim();
          }
        }
        if (bestSnippet.isEmpty) bestSnippet = content.trim();
        if (bestSnippet.isEmpty) continue;
        results.add({
          'title':   doc['title'],
          'snippet': bestSnippet.length > snippetChars
              ? '${bestSnippet.substring(0, snippetChars)}...'
              : bestSnippet,
          'score': score,
          // Provenance — lets callers cite a clause and mark unverified scans.
          // Kept nullable: ordinary uploaded/seeded docs have none of these.
          'id':        doc['id'],
          'source':    doc['source'],
          'sopNumber': doc['sopNumber'],
          'clauseNo':  doc['clauseNo'],
          'docGroup':  doc['docGroup'],
          'pageFrom':  doc['pageFrom'],
          'verified':  doc['verified'] == true,
        });
      }
    }
    results.sort(
        (a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return results.take(limit < 1 ? 1 : limit).toList();
  }

  // ★ Safety synonym map for KB search expansion
  static const Map<String, List<String>> _safetySynonyms = {
    'loto': ['lock', 'tag', 'isolation', 'isolate', 'energy control'],
    'lockout': ['lock', 'tag', 'isolation', 'isolate'],
    'lototo': ['lock', 'tag', 'try out', 'isolation', 'energy control'],
    'confined': ['enclosed', 'closed', 'tight', 'vessel', 'tank'],
    'height': ['elevated', 'working at height', 'fall', 'harness', 'scaffold'],
    'harness': ['fall arrest', 'fall restraint', 'lanyard', 'anchor'],
    'gas': ['cylinder', 'compressed', 'oxygen', 'acetylene', 'lpg'],
    'cylinder': ['gas', 'compressed', 'bottle'],
    'permit': ['ptw', 'permit to work', 'authorization'],
    'hot work': ['welding', 'cutting', 'grinding', 'spark', 'fire'],
    'fire': ['flame', 'combustion', 'ignition', 'extinguisher'],
    'electrical': ['electric', 'arc flash', 'shock', 'electrocution', 'voltage'],
    'ppe': ['personal protective', 'helmet', 'gloves', 'safety shoes', 'goggles'],
    'helmet': ['hard hat', 'safety hat', 'head protection'],
    'gloves': ['hand protection', 'hand safety'],
    'conveyor': ['belt', 'nip point', 'roller', 'transfer'],
    'crane': ['lifting', 'hoist', 'sling', 'overhead'],
    'blast furnace': ['bf', 'furnace', 'tuyere', 'cast house'],
    'coke oven': ['battery', 'coking', 'by-product'],
    'bof': ['converter', 'sms', 'steelmaking'],
    'rolling mill': ['hsm', 'crm', 'plate mill', 'bar mill'],
    'accident': ['incident', 'injury', 'near miss', 'occurrence'],
    'incident': ['accident', 'injury', 'near miss', 'occurrence'],
    'near miss': ['close call', 'almost incident', 'hazard'],
    'hazard': ['danger', 'risk', 'threat', 'unsafe'],
    'risk': ['hazard', 'danger', 'likelihood', 'severity'],
    'emergency': ['rescue', 'evacuation', 'first aid', 'response'],
    'scaffold': ['scaffolding', 'platform', 'working platform'],
    'welding': ['hot work', 'arc', 'gas welding'],
    'acid': ['chemical', 'corrosive', 'pickling'],
    'noise': ['sound', 'decibel', 'hearing protection'],
    'dust': ['particulate', 'fume', 'vapour', 'aerosol'],
    'molten': ['liquid metal', 'hot metal', 'molten metal'],
    'ventilation': ['exhaust', 'fume extraction', 'air flow'],
    'inspection': ['check', 'audit', 'examination', 'survey'],
    'maintenance': ['repair', 'overhaul', 'shutdown'],
  };

  // ★ Generate fuzzy variants (1-char substitution/deletion)
  static List<String> _fuzzyVariants(String word) {
    final variants = <String>{};
    const alphabet = 'abcdefghijklmnopqrstuvwxyz';
    for (int i = 0; i < word.length; i++) {
      for (final c in alphabet.split('')) {
        if (c != word[i]) {
          variants.add('${word.substring(0, i)}$c${word.substring(i + 1)}');
        }
      }
    }
    for (int i = 0; i < word.length; i++) {
      variants.add('${word.substring(0, i)}${word.substring(i + 1)}');
    }
    return variants.take(20).toList();
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW: SEED KNOWLEDGE BASE
  //  Wipes existing KB (if replace=true), loads 38 default entries
  //  covering Factories Act 1948 + Chhattisgarh/Odisha/TN/Bihar rules.
  //  Returns count of entries added.
  // ═══════════════════════════════════════════════════════════════
  static Future<int> seedKnowledgeBase({bool replace = true}) async {
    if (replace) {
      await _prefs.remove(_kKbDocs);
    }

    final all      = <Map<String, dynamic>>[];
    final userName = (await getCurrentUser())?['name'] ?? 'system-seed';
    int added = 0;

    for (final entry in KbSeedData.entries) {
      try {
        all.add({
          'id':         'seed-${DateTime.now().millisecondsSinceEpoch}-$added',
          'title':      entry['title']  ?? 'Untitled',
          'content':    entry['content'] ?? '',
          'source':     entry['source']  ?? 'Default seed',
          'uploadedAt': DateTime.now().toIso8601String(),
          'uploadedBy': userName,
        });
        added++;
      } catch (_) {
        // Skip the one bad entry, continue
      }
    }

    // If not replacing, merge with existing KB first
    if (!replace) {
      final existing = await getKnowledgeDocs();
      all.insertAll(0, existing);
    }

    await _prefs.setString(_kKbDocs, jsonEncode(all));
    _bumpKb();
    return added;
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW: RESET ALL DATA
  //  Clears incidents + feedback + sync caches.
  //  Optionally clears KB / users / login.
  // ═══════════════════════════════════════════════════════════════
  static Future<void> resetAllData({
    bool keepUsers = true,
    bool keepKb    = true,
    bool keepLogin = true,
  }) async {
    // 1. Always clear incidents
    await _prefs.remove(_kIncidents);

    // 2. Always clear feedback/learning data linked to past scans
    await _prefs.remove(_kFeedback);
    await _prefs.remove(_kCustomHazards);

    // 3. Clear best-effort caches if they exist (no-op if absent)
    await _prefs.remove('image_hashes');
    await _prefs.remove('sync_queue');
    await _prefs.remove('pending_pdfs');
    await _prefs.remove('chat_history');

    // 4. Optional clears
    if (!keepKb) {
      await _prefs.remove(_kKbDocs);
      _bumpKb();
    }
    if (!keepUsers) {
      await _prefs.remove(_kUsers);
      await _prefs.remove(_kCachedUsers);
    }
    if (!keepLogin) await _prefs.remove(_kCurrentUser);
  }

  // ═══════════════════════════════════════════════════════════════
  //  ✅ NEW: DATA COUNTS — for confirmation dialogs
  // ═══════════════════════════════════════════════════════════════
  static Future<Map<String, int>> dataCounts() async {
    int incidents = 0, kb = 0, users = 0;
    try {
      final raw = _prefs.getString(_kIncidents);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) incidents = list.length;
      }
    } catch (_) {}
    try {
      final raw = _prefs.getString(_kKbDocs);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) kb = list.length;
      }
    } catch (_) {}
    try {
      final raw = _prefs.getString(_kUsers);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) users = list.length;
      }
    } catch (_) {}
    return {'incidents': incidents, 'kb': kb, 'users': users};
  }

  // ═══════════════════════════════════════════════════════════════
  //  AI CORRECTIONS — local mirror of user edits to AI output
  //  Records are keyed by id. This local store is (a) an offline queue
  //  that AiCorrectionService flushes to Supabase when online, and
  //  (b) a fallback the admin panel reads when the backend is down.
  // ═══════════════════════════════════════════════════════════════
  static Future<List<Map<String, dynamic>>> getAiCorrections() async {
    final raw = _prefs.getString(_kAiCorrections);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Insert or update a correction (keyed by id).
  static Future<void> saveAiCorrection(Map<String, dynamic> correction) async {
    final id = correction['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final all = await getAiCorrections();
    final idx = all.indexWhere((c) => c['id']?.toString() == id);
    if (idx >= 0) {
      all[idx] = {...all[idx], ...correction};
    } else {
      all.add(correction);
    }
    await _prefs.setString(_kAiCorrections, jsonEncode(all));
  }

  /// Merge a batch of correction rows (e.g. pulled from Supabase) into the
  /// local store, keeping the newest version of each by id.
  static Future<void> mergeAiCorrections(
      List<Map<String, dynamic>> incoming) async {
    if (incoming.isEmpty) return;
    final all = await getAiCorrections();
    final byId = {for (final c in all) c['id']?.toString() ?? '': c};
    for (final c in incoming) {
      final id = c['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      byId[id] = {...?byId[id], ...c};
    }
    await _prefs.setString(_kAiCorrections, jsonEncode(byId.values.toList()));
  }

  static Future<void> clearAiCorrections() async {
    await _prefs.remove(_kAiCorrections);
  }
}
