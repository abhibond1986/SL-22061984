// lib/services/supabase_service.dart
// Phase 1 of the Supabase migration (see SUPABASE_MIGRATION_GUIDE.md).
//
// Provides the incidents data path (fetch / upsert / delete) and image upload
// to Supabase Storage. Mirrors the shape of SyncService's incident methods so
// callers can switch backends via SupabaseConfig.enabled with no other change.
//
// Offline-first is preserved: these methods are the REMOTE layer only. The
// local SharedPreferences cache (LocalDB) is untouched — callers still read
// local first and sync through here when online.

import 'dart:convert';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';

class SupabaseService {
  static bool _initialized = false;

  /// Initialize Supabase once at app startup. No-op if disabled/unconfigured.
  static Future<void> init() async {
    if (!SupabaseConfig.enabled || _initialized) return;
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    _initialized = true;
  }

  static bool get isReady => SupabaseConfig.enabled && _initialized;

  static SupabaseClient get _db => Supabase.instance.client;

  /// Public accessor so other services (e.g. realtime) can reuse the client.
  static SupabaseClient get client => _db;

  /// Convert a DB incident row (snake_case) to the app map (camelCase).
  /// Exposed for the realtime layer, which receives raw rows from Postgres.
  static Map<String, dynamic> incidentFromRow(Map<String, dynamic> row) =>
      _fromRow(row);

  // ══════════════════════════════════════════════════════════════════════════
  //  FIELD MAPPING — app (camelCase) ↔ DB (snake_case)
  // ══════════════════════════════════════════════════════════════════════════
  // Only the keys we persist are mapped; unknown keys are dropped on write.
  static const Map<String, String> _appToDb = {
    'id': 'id',
    'title': 'title',
    'type': 'type',
    'plant': 'plant',
    'dept': 'dept',
    'location': 'location',
    'detectedSection': 'detected_section',
    'severity': 'severity',
    'status': 'status',
    'wsaCategory': 'wsa_category',
    'obsType': 'obs_type',
    'summary': 'summary',
    'desc': 'description',
    'immediateAction': 'immediate_action',
    'rootCause': 'root_cause',
    'correctiveAction': 'corrective_action',
    'hazards': 'hazards',
    'riskScore': 'risk_score',
    'confidence': 'confidence',
    'people': 'people',
    'reportedBy': 'reported_by',
    'reportedByPno': 'reported_by_pno',
    'imageUrl': 'image_url',
    'imageHash': 'image_hash',
    'latitude': 'latitude',
    'longitude': 'longitude',
    'locationAccuracy': 'location_accuracy',
    'locationAddress': 'location_address',
    'locationTimestamp': 'location_timestamp',
    'auditStatus': 'audit_status',
    'auditScore': 'audit_score',
    'date': 'date',
  };
  static final Map<String, String> _dbToApp = {
    for (final e in _appToDb.entries) e.value: e.key,
  };

  /// Convert an app incident map to a DB row (snake_case, JSON-encoded lists).
  static Map<String, dynamic> _toRow(Map<String, dynamic> inc) {
    final row = <String, dynamic>{};
    _appToDb.forEach((appKey, dbCol) {
      if (!inc.containsKey(appKey)) return;
      var v = inc[appKey];
      if (appKey == 'hazards') {
        // Store as jsonb — pass a List/Map through; parse if it's a JSON string.
        if (v is String) { try { v = jsonDecode(v); } catch (_) {} }
      }
      if (appKey == 'people' || appKey == 'riskScore' ||
          appKey == 'confidence' || appKey == 'auditScore') {
        v = v == null ? null : int.tryParse(v.toString());
      }
      row[dbCol] = v;
    });
    return row;
  }

  /// Convert a DB row back to the app's incident map (camelCase).
  static Map<String, dynamic> _fromRow(Map<String, dynamic> row) {
    final inc = <String, dynamic>{};
    row.forEach((dbCol, v) {
      final appKey = _dbToApp[dbCol];
      if (appKey == null) return;
      inc[appKey] = v;
    });
    // hazards comes back as a List/Map (jsonb) — leave as-is; callers handle both.
    return inc;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  INCIDENTS
  // ══════════════════════════════════════════════════════════════════════════

  /// Fetch all incidents (newest first). Returns [] on any error.
  static Future<List<Map<String, dynamic>>> fetchIncidents() async {
    if (!isReady) return [];
    try {
      final rows = await _db
          .from('incidents')
          .select()
          .order('date', ascending: false);
      return (rows as List)
          .map((r) => _fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Like [fetchIncidents] but returns null on ANY failure (network, auth,
  /// timeout) so callers can distinguish "server is genuinely empty" from
  /// "couldn't reach the server". An empty-but-successful fetch returns [].
  /// Used by server-authoritative reconciliation, which must NEVER delete the
  /// local cache just because a request failed.
  static Future<List<Map<String, dynamic>>?> fetchIncidentsOrNull() async {
    if (!isReady) return null;
    try {
      final rows = await _db
          .from('incidents')
          .select()
          .order('date', ascending: false);
      return (rows as List)
          .map((r) => _fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Insert or update one incident (keyed by id). Returns true on success.
  static Future<bool> upsertIncident(Map<String, dynamic> incident) async {
    if (!isReady) return false;
    try {
      final row = _toRow(incident);
      if ((row['id']?.toString() ?? '').isEmpty) return false;
      await _db.from('incidents').upsert(row, onConflict: 'id');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Hard-delete an incident by id. Also removes its evidence image from
  /// Storage so no orphaned file is left behind. Returns true on success.
  static Future<bool> deleteIncident(String id) async {
    if (!isReady || id.isEmpty) return false;
    try {
      await _db.from('incidents').delete().eq('id', id);
      // Best-effort image cleanup — never let a missing/absent file fail the
      // delete (the row is already gone, which is what matters).
      try {
        await _db.storage
            .from(SupabaseConfig.imageBucket)
            .remove(['img_$id.jpg']);
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  IMAGE STORAGE — upload once, reference by public URL everywhere
  // ══════════════════════════════════════════════════════════════════════════

  /// Upload incident evidence bytes to the Storage bucket and return the public
  /// URL (to store in incident['imageUrl']). Returns null on failure.
  static Future<String?> uploadIncidentImage(
      String incidentId, Uint8List bytes) async {
    if (!isReady || incidentId.isEmpty || bytes.isEmpty) return null;
    final path = 'img_$incidentId.jpg';
    // NOTE: upsert:true issues an UPDATE on storage.objects, which requires an
    // UPDATE policy the bucket may not have (only INSERT+SELECT). So try a plain
    // insert first (works with the default policies for a NEW image), and only
    // fall back to upsert for a genuine overwrite. This lets image storage work
    // even before supabase_dashboard_setup.sql adds the UPDATE/DELETE policies.
    try {
      await _db.storage.from(SupabaseConfig.imageBucket).uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: false, // plain insert — succeeds with INSERT policy alone
            ),
          );
      return _db.storage.from(SupabaseConfig.imageBucket).getPublicUrl(path);
    } catch (_) {
      // Object already exists (re-save) → needs an overwrite via upsert, which
      // requires the UPDATE policy from supabase_dashboard_setup.sql.
      try {
        await _db.storage.from(SupabaseConfig.imageBucket).uploadBinary(
              path,
              bytes,
              fileOptions: const FileOptions(
                contentType: 'image/jpeg',
                upsert: true,
              ),
            );
        return _db.storage.from(SupabaseConfig.imageBucket).getPublicUrl(path);
      } catch (_) {
        return null;
      }
    }
  }

  /// Download image bytes for an incident that has an imageUrl. Returns null
  /// if there's no URL or the fetch fails. (Works on web AND mobile.)
  static Future<Uint8List?> downloadIncidentImage(String incidentId) async {
    if (!isReady || incidentId.isEmpty) return null;
    try {
      final path = 'img_$incidentId.jpg';
      return await _db.storage
          .from(SupabaseConfig.imageBucket)
          .download(path);
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  USERS (app_users table — custom login, NOT Supabase Auth)
  // ══════════════════════════════════════════════════════════════════════════
  static const Map<String, String> _userAppToDb = {
    'username': 'username',
    'name': 'name',
    'designation': 'designation',
    'plant': 'plant',
    'department': 'department',
    'pno': 'pno',
    'mobile': 'mobile',
    'email': 'email',
    'isAdmin': 'is_admin',
    'status': 'status',
    'passwordHash': 'password_hash',
    'salt': 'salt',
  };
  static final Map<String, String> _userDbToApp = {
    for (final e in _userAppToDb.entries) e.value: e.key,
  };

  static Map<String, dynamic> _userToRow(Map<String, dynamic> u) {
    final row = <String, dynamic>{};
    _userAppToDb.forEach((appKey, dbCol) {
      if (!u.containsKey(appKey)) return;
      var v = u[appKey];
      if (appKey == 'isAdmin') {
        v = v is bool ? v : v?.toString().toLowerCase() == 'true';
      }
      row[dbCol] = v;
    });
    return row;
  }

  static Map<String, dynamic> _userFromRow(Map<String, dynamic> row) {
    final u = <String, dynamic>{};
    row.forEach((dbCol, v) {
      final appKey = _userDbToApp[dbCol];
      if (appKey != null) u[appKey] = v;
    });
    return u;
  }

  /// Fetch all users. Returns [] on error.
  static Future<List<Map<String, dynamic>>> fetchUsers() async {
    if (!isReady) return [];
    try {
      final rows = await _db.from('app_users').select();
      return (rows as List)
          .map((r) => _userFromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Insert or update a user (keyed by username). Returns true on success.
  static Future<bool> upsertUser(Map<String, dynamic> user) async {
    if (!isReady) return false;
    try {
      final row = _userToRow(user);
      if ((row['username']?.toString() ?? '').isEmpty) return false;
      await _db.from('app_users').upsert(row, onConflict: 'username');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Delete a user by username. Returns true on success.
  static Future<bool> deleteUser(String username) async {
    if (!isReady || username.isEmpty) return false;
    try {
      await _db.from('app_users').delete().eq('username', username);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Look up one user by username (for cross-device login). Returns the app-shaped
  /// map (including password_hash/salt so the caller can verify), or null.
  static Future<Map<String, dynamic>?> getUserByUsername(String username) async {
    if (!isReady || username.isEmpty) return null;
    try {
      final rows = await _db
          .from('app_users')
          .select()
          .eq('username', username)
          .limit(1);
      final list = rows as List;
      if (list.isEmpty) return null;
      return _userFromRow(Map<String, dynamic>.from(list.first as Map));
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  KNOWLEDGE BASE (knowledge_docs table)
  // ══════════════════════════════════════════════════════════════════════════

  /// Fetch all KB docs (title/content/source). Returns [] on error.
  static Future<List<Map<String, dynamic>>> fetchKnowledgeDocs() async {
    if (!isReady) return [];
    try {
      final rows = await _db
          .from('knowledge_docs')
          .select('title, content, source')
          .order('created_at', ascending: false);
      return (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Insert one KB doc. Returns true on success.
  static Future<bool> addKnowledgeDoc(Map<String, dynamic> doc) async {
    if (!isReady) return false;
    try {
      await _db.from('knowledge_docs').insert({
        'title':   doc['title']?.toString() ?? 'Untitled',
        'content': doc['content']?.toString() ?? '',
        'source':  doc['source']?.toString() ?? 'uploaded',
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MASTER DATA (master_data key→jsonb)
  // ══════════════════════════════════════════════════════════════════════════

  /// Save one master-data list under [key] (e.g. 'plants'). Value is any
  /// JSON-serializable structure (list of strings or list of maps).
  static Future<bool> setMasterData(String key, dynamic value) async {
    if (!isReady || key.isEmpty) return false;
    try {
      await _db.from('master_data').upsert(
        {'key': key, 'value': value, 'updated_at': DateTime.now().toIso8601String()},
        onConflict: 'key',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fetch all master-data as a { key: value } map. Returns {} on error.
  static Future<Map<String, dynamic>> fetchMasterData() async {
    if (!isReady) return {};
    try {
      final rows = await _db.from('master_data').select('key, value');
      final out = <String, dynamic>{};
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final k = m['key']?.toString();
        if (k != null) out[k] = m['value'];
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  DEVICE TOKENS (device_tokens — FCM push registration)
  // ══════════════════════════════════════════════════════════════════════════

  /// Register (upsert) an FCM device token. Returns true on success.
  static Future<bool> registerDeviceToken({
    required String token,
    String username = '',
    String plant = '',
    String platform = '',
  }) async {
    if (!isReady || token.isEmpty) return false;
    try {
      await _db.from('device_tokens').upsert(
        {
          'token': token,
          'username': username,
          'plant': plant,
          'platform': platform,
        },
        onConflict: 'token',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  AI CORRECTIONS (ai_corrections — user edits to AI output, admin review)
  // ══════════════════════════════════════════════════════════════════════════
  static const Map<String, String> _corrAppToDb = {
    'id': 'id',
    'incidentId': 'incident_id',
    'incidentType': 'incident_type',
    'imageHash': 'image_hash',
    'plant': 'plant',
    'fieldChanged': 'field_changed',
    'hazardName': 'hazard_name',
    'originalValue': 'original_value',
    'editedValue': 'edited_value',
    'editedBy': 'edited_by',
    'aiSource': 'ai_source',
    'verdict': 'verdict',
    'reviewedBy': 'reviewed_by',
    'reviewedAt': 'reviewed_at',
    'addedToTraining': 'added_to_training',
    'createdAt': 'created_at',
  };
  static final Map<String, String> _corrDbToApp = {
    for (final e in _corrAppToDb.entries) e.value: e.key,
  };

  static Map<String, dynamic> _corrToRow(Map<String, dynamic> c) {
    final row = <String, dynamic>{};
    _corrAppToDb.forEach((appKey, dbCol) {
      if (!c.containsKey(appKey)) return;
      var v = c[appKey];
      if (appKey == 'addedToTraining') {
        v = v is bool ? v : v?.toString().toLowerCase() == 'true';
      }
      // Empty strings for timestamptz columns must become null.
      if (dbCol == 'reviewed_at' && (v == null || v.toString().isEmpty)) {
        v = null;
      }
      row[dbCol] = v;
    });
    return row;
  }

  static Map<String, dynamic> _corrFromRow(Map<String, dynamic> row) {
    final c = <String, dynamic>{};
    row.forEach((dbCol, v) {
      final appKey = _corrDbToApp[dbCol];
      if (appKey != null) c[appKey] = v;
    });
    return c;
  }

  /// Fetch all AI corrections (newest first). Returns [] on any error / when
  /// Supabase is disabled.
  static Future<List<Map<String, dynamic>>> fetchCorrections() async {
    if (!isReady) return [];
    try {
      // Timeout guard: if the table is missing or the network stalls, never
      // let this hang — the admin panel awaits this call before showing data.
      final rows = await _db
          .from('ai_corrections')
          .select()
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 8));
      return (rows as List)
          .map((r) => _corrFromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Insert or update one AI correction (keyed by id). Returns true on success.
  static Future<bool> upsertCorrection(Map<String, dynamic> correction) async {
    if (!isReady) return false;
    try {
      final row = _corrToRow(correction);
      if ((row['id']?.toString() ?? '').isEmpty) return false;
      await _db.from('ai_corrections').upsert(row, onConflict: 'id');
      return true;
    } catch (_) {
      return false;
    }
  }
}
