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
import 'package:flutter/foundation.dart' show debugPrint;
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
  //
  // ⚠ Adding a key here is only half the job — the column must also exist in
  // the `incidents` table, or the whole upsert fails (PostgREST rejects the
  // entire row for one unknown column, so a missing column silently breaks
  // ALL syncing, not just that field). See migration_workflow_fields.sql.
  //
  // This map used to omit every closure/assignment field: closedBy,
  // closingRemarks, closedAt, assignedTo, assignedAt, investigationStartedAt
  // and actionTakenAt. A user could type a corrective action and close an
  // incident, and none of it left the device — then the next realtime UPDATE
  // for that id replaced the local record with a server row that lacked those
  // fields, erasing the work. That is why the workflow block below exists.
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
    // ── Workflow / closure fields ──
    'investigationStartedAt': 'investigation_started_at',
    'actionTakenAt': 'action_taken_at',
    'closedBy': 'closed_by',
    'closingRemarks': 'closing_remarks',
    'closedAt': 'closed_at',
    'assignedTo': 'assigned_to',
    // Denormalised on purpose. The assignee is a P.no ("a000168"), which tells a
    // supervisor on another device nothing, and resolving 10,000 usernames to
    // names for a list of incidents is not a query worth running. Added by
    // migration_bulk_users.sql.
    'assignedToName': 'assigned_to_name',
    'assignedAt': 'assigned_at',
    'targetDate': 'target_date',
    'updatedAt': 'updated_at',
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

  // ── Schema-gap tolerance ──────────────────────────────────────────────────
  // Columns PostgREST has told us do not exist on `incidents`.
  //
  // Why this exists: PostgREST rejects the ENTIRE row when ONE column is
  // unknown. So a single un-run migration does not merely drop a field, it
  // silently breaks ALL incident syncing — a user closes an incident and types
  // closing remarks, none of it leaves the device, and then the next realtime
  // UPDATE for that id replaces the local record with a server row that lacks
  // those fields, erasing the work. That is a data-loss bug, not a cosmetic
  // one, and it is invisible because upsert failures were swallowed.
  //
  // Rather than lose the whole record, learn the missing column names from the
  // error, drop just those, and retry so everything else still lands.
  //
  // This is a SAFETY NET, not a substitute for running the migration: the
  // dropped fields genuinely do not persist. [incidentSchemaGaps] is exposed so
  // the admin panel can say so out loud instead of failing quietly.
  static final Set<String> _incidentMissingCols = <String>{};

  /// Sorted list of `incidents` columns the server has rejected as unknown.
  /// Non-empty means a migration is outstanding (see migration_workflow_fields.sql).
  static List<String> get incidentSchemaGaps =>
      _incidentMissingCols.toList()..sort();

  /// Last incident-write error, for diagnostics. Empty after a clean write.
  static String incidentsLastError = '';

  /// Extract the offending column from a PostgREST undefined-column error.
  /// Three message shapes occur in the wild, so all three are handled:
  ///   42703    → `column incidents.closed_at does not exist`
  ///   42703    → `column "closed_by" does not exist`   (quoted identifier)
  ///   PGRST204 → `Could not find the 'closed_at' column of 'incidents' ...`
  /// Returns null for any other failure, so genuine network/auth/RLS errors are
  /// NOT mistaken for a schema gap (which would strip columns for no reason).
  static String? _missingColumnFrom(Object e) {
    if (e is! PostgrestException) return null;
    final code = (e.code ?? '').toUpperCase();
    final msg = e.message;
    // 42P01 is a missing TABLE, not a missing column. Its message also ends in
    // "does not exist", so without this it would fall through to the patterns
    // below and yield a table name that we would then try to strip as a column.
    if (code == '42P01') return null;
    if (code != '42703' && code != 'PGRST204') {
      // Some gateways omit the code; fall back to the message shape.
      if (!msg.contains('does not exist') && !msg.contains('Could not find')) {
        return null;
      }
    }
    // PGRST204: `... the 'closed_at' column of 'incidents' ...`
    final quoted = RegExp("'([A-Za-z0-9_]+)' column").firstMatch(msg);
    if (quoted != null) return quoted.group(1);
    // Quoted identifier. The character class excludes '.' on purpose so that
    // `relation "public.incidents" does not exist` cannot match here.
    final dquoted =
        RegExp(r'"([A-Za-z0-9_]+)"\s+does not exist').firstMatch(msg);
    if (dquoted != null) return dquoted.group(1);
    // Bare or qualified: `column incidents.closed_at does not exist` and the
    // fully-qualified `column public.incidents.assigned_to does not exist`.
    // The prefix repeats (`*`, not `?`) so schema.table.column also matches.
    final dotted =
        RegExp(r'column\s+(?:[A-Za-z0-9_]+\.)*([A-Za-z0-9_]+)\s+does not exist')
            .firstMatch(msg);
    if (dotted != null) return dotted.group(1);
    return null;
  }

  /// Insert or update one incident (keyed by id). Returns true on success.
  ///
  /// Tolerates a server whose schema is behind the app: unknown columns are
  /// dropped and the write is retried, so a missing migration costs those
  /// fields rather than the entire record.
  static Future<bool> upsertIncident(Map<String, dynamic> incident) async {
    if (!isReady) return false;
    final row = _toRow(incident);
    if ((row['id']?.toString() ?? '').isEmpty) return false;

    // Skip columns already known to be absent — avoids a guaranteed round trip
    // on every subsequent write once the gap has been discovered.
    for (final c in _incidentMissingCols) {
      row.remove(c);
    }

    // One retry per mappable column, so a schema several columns behind
    // converges instead of giving up after the first rejection.
    final maxAttempts = _appToDb.length + 1;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await _db.from('incidents').upsert(row, onConflict: 'id');
        incidentsLastError = '';
        return true;
      } catch (e) {
        final missing = _missingColumnFrom(e);
        // Never strip the primary key: without `id` the upsert has no conflict
        // target and would insert duplicates instead of updating.
        if (missing == null ||
            missing == 'id' ||
            !row.containsKey(missing)) {
          incidentsLastError = _describeError(e);
          return false;
        }
        _incidentMissingCols.add(missing);
        row.remove(missing);
        incidentsLastError = 'dropped unknown column "$missing" — '
            'run migration_workflow_fields.sql';
      }
    }
    return false;
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
    // ── Employee-list profile fields (migration_bulk_users.sql) ──
    // Added for the quarterly bulk import. Any key absent from this map is
    // SILENTLY DROPPED by _userToRow, so a new profile field that is not listed
    // here will appear to save on the device and never reach the server.
    'grade': 'grade',
    'unit': 'unit',
    'dob': 'dob',
    'retireDate': 'retire_dt',
    'mustChangePassword': 'must_change_password',
    'importSource': 'import_source',
    'importBatch': 'import_batch',
    'importedAt': 'imported_at',
    'updatedAt': 'updated_at',
  };

  /// Columns typed `date` / `boolean` in Postgres that the app may hold as a
  /// String. PostgREST rejects `""` for a date column (it is not a valid date)
  /// with a 400 that would fail the whole batch, so an empty value must become
  /// null. 202 rows in the January 2026 file have no email and 9 have no dates,
  /// so this is the normal case, not an edge case.
  static const Set<String> _userDateCols = {'dob', 'retire_dt'};
  static const Set<String> _userBoolCols = {'is_admin', 'must_change_password'};
  static final Map<String, String> _userDbToApp = {
    for (final e in _userAppToDb.entries) e.value: e.key,
  };

  static Map<String, dynamic> _userToRow(Map<String, dynamic> u) {
    final row = <String, dynamic>{};
    _userAppToDb.forEach((appKey, dbCol) {
      if (!u.containsKey(appKey)) return;
      var v = u[appKey];
      if (_userBoolCols.contains(dbCol)) {
        v = v is bool ? v : v?.toString().toLowerCase() == 'true';
      } else if (_userDateCols.contains(dbCol)) {
        final s = v?.toString().trim() ?? '';
        v = s.isEmpty ? null : s;
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

  /// Last error from an app_users operation. Empty when the last call
  /// succeeded. Auth failures used to be indistinguishable from "user not
  /// found" because every method swallowed its exception — which is how a
  /// missing table or an RLS denial ended up being reported to the user as
  /// "Invalid credentials".
  static String usersLastError = '';

  /// Set when the Supabase client isn't initialised at all. It must be a
  /// distinct, non-empty value: the app_users helpers used to return
  /// false/null on `!isReady` WITHOUT touching usersLastError, so callers
  /// evaluated `usersSchemaMissing` against a stale error left by some earlier
  /// unrelated call — and told the user to "run the app_users migration" when
  /// the real problem was that the cloud was switched off. Worded so it can
  /// never satisfy usersSchemaMissing.
  static const String _notReady = 'cloud client not initialised';

  /// True when the last failure means the table/columns aren't there yet
  /// (i.e. the migration SQL was never run), as opposed to a network blip.
  static bool get usersSchemaMissing {
    final e = usersLastError.toLowerCase();
    return e.contains('42p01') ||
        e.contains('pgrst205') ||
        e.contains('42703') || // undefined_column
        e.contains('does not exist') ||
        e.contains('could not find the');
  }

  /// True when the last [fetchUsers] returned a full page and therefore almost
  /// certainly left rows behind.
  ///
  /// This exists because the truncation used to be invisible. PostgREST caps an
  /// unbounded select at its configured maximum (1000 by default) and returns
  /// 200 OK with a short list — no error, no warning. After the quarterly import
  /// the roster is ~10,000 people, so every caller of fetchUsers() was quietly
  /// looking at the first tenth of the company while a "1000 total" badge sat on
  /// screen looking authoritative. Callers must now say so.
  static bool usersTruncated = false;

  /// Fetch users, newest-relevant first. Returns [] on error.
  ///
  /// [limit] is explicit and applied server-side rather than left to PostgREST's
  /// default, so the number on screen is a number this code chose. Do NOT raise
  /// it to cover the whole roster: the result is cached to device storage by
  /// SyncService, and 10,000 rows is ~2.3 MB against a ~5 MB browser origin
  /// budget already shared with incident photos. Search the server instead —
  /// see [searchUsers].
  static Future<List<Map<String, dynamic>>> fetchUsers({int limit = 1000}) async {
    if (!isReady) {
      usersLastError = _notReady;
      usersTruncated = false;
      return [];
    }
    try {
      // Ordered by name so the truncated page is at least a predictable slice
      // rather than whatever order Postgres happened to return.
      final rows = await _db.from('app_users').select().order('name').limit(limit);
      usersLastError = '';
      final list = (rows as List)
          .map((r) => _userFromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
      usersTruncated = list.length >= limit;
      return list;
    } catch (e) {
      usersLastError = _describeError(e);
      usersTruncated = false;
      return [];
    }
  }

  /// Total number of accounts, or null if it could not be determined.
  ///
  /// Delegates to [fetchAllUsernames], which pages with `.range` — the only way
  /// in this file that is known to see past row 1000. A plain `select('username')`
  /// would be capped at 1000 and would confidently report "1000 users" for a
  /// 10,086-person roster, which is precisely the failure this method exists to
  /// stop. `.count()` on the query builder is deliberately not used: its surface
  /// varies across the supabase_flutter 2.x line this project pins, and nothing
  /// here can be compiled to check.
  ///
  /// Cost is one short string per employee (~10 KB per page, discarded after
  /// counting), so this is for a screen the admin opened — not for every load.
  static Future<int?> countUsers() async {
    final all = await fetchAllUsernames();
    return all?.length;
  }

  /// Insert or update a user (keyed by username). Returns true on success.
  static Future<bool> upsertUser(Map<String, dynamic> user) async {
    if (!isReady) {
      usersLastError = _notReady;
      return false;
    }
    try {
      final row = _userToRow(user);
      if ((row['username']?.toString() ?? '').isEmpty) {
        usersLastError = 'username missing';
        return false;
      }
      // Usernames are matched case-insensitively by the app but `onConflict`
      // is a plain equality check in Postgres, so "RKumar" and "rkumar" would
      // become two rows. Normalise here as a backstop, not just at the caller.
      row['username'] = row['username'].toString().trim().toLowerCase();
      await _db
          .from('app_users')
          .upsert(row, onConflict: 'username')
          .timeout(const Duration(seconds: 12));
      usersLastError = '';
      return true;
    } catch (e) {
      usersLastError = _describeError(e);
      return false;
    }
  }

  // ── BULK ROSTER OPERATIONS (quarterly employee import) ───────────────────
  //
  // The SAIL employee list is ~10,000 rows. Everything in this section exists
  // because the single-row helpers above do not survive that scale:
  //
  //   • upsertUser() one row at a time is ~10,000 round trips. At even 80ms
  //     each that is 13 minutes of an admin staring at a progress bar, and any
  //     dropped connection leaves the roster half-written.
  //   • fetchUsers() cannot see the whole roster. PostgREST caps a response at
  //     its configured maximum (1000 rows by default), so on a full roster it
  //     returns a TRUNCATED list — which would read as "these users do not
  //     exist" and let the importer recreate them. It now applies that limit
  //     explicitly and raises [usersTruncated], but the limit is still there:
  //     the importer must use fetchAllUsernames(), which pages with .range.
  //
  // So: write in chunks, and never load the roster to search it.

  /// Rows per upsert request. 500 keeps each request comfortably inside
  /// PostgREST's payload limits while cutting 10,000 rows to ~20 requests.
  static const int kUserBatchSize = 500;

  /// Upsert many users in chunks, keyed by username.
  ///
  /// Returns the number of rows successfully written. A chunk that fails does
  /// NOT abort the rest — a single malformed row out of 10,000 must not cost the
  /// other 9,999 — and every failure is appended to [usersLastError] so the
  /// caller can show the admin what did not land.
  ///
  /// [onProgress] is called with (written, total) after each chunk so the UI can
  /// show real progress rather than an indeterminate spinner.
  static Future<int> upsertUsers(
    List<Map<String, dynamic>> users, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (!isReady) {
      usersLastError = _notReady;
      return 0;
    }
    final rows = <Map<String, dynamic>>[];
    for (final u in users) {
      final row = _userToRow(u);
      final name = row['username']?.toString().trim().toLowerCase() ?? '';
      if (name.isEmpty) continue; // caller validates; this is a backstop
      row['username'] = name;
      rows.add(row);
    }

    final errors = <String>[];
    int written = 0;
    for (var i = 0; i < rows.length; i += kUserBatchSize) {
      final end =
          (i + kUserBatchSize) > rows.length ? rows.length : i + kUserBatchSize;
      final chunk = rows.sublist(i, end);
      try {
        await _db
            .from('app_users')
            .upsert(chunk, onConflict: 'username')
            // Generous: 500 rows over a plant-floor connection is not fast.
            .timeout(const Duration(seconds: 60));
        written += chunk.length;
      } catch (e) {
        errors.add('rows ${i + 1}-$end: ${_describeError(e)}');
      }
      onProgress?.call(written, rows.length);
    }
    usersLastError = errors.isEmpty ? '' : errors.join(' | ');
    return written;
  }

  /// Set `status` for many usernames at once, without touching anything else.
  ///
  /// Used to deactivate the people an admin selected from the "in the portal but
  /// not in this quarter's file" list. Deliberately an UPDATE of one column
  /// rather than an upsert of whole rows: the admin panel's copy of those users
  /// may be stale, and disabling an account must not silently revert someone's
  /// plant or designation as a side effect.
  static Future<int> setUsersStatus(
      List<String> usernames, String status) async {
    if (!isReady) {
      usersLastError = _notReady;
      return 0;
    }
    final names = usernames
        .map((u) => u.trim().toLowerCase())
        .where((u) => u.isNotEmpty)
        .toList();
    if (names.isEmpty) return 0;

    final errors = <String>[];
    int changed = 0;
    for (var i = 0; i < names.length; i += kUserBatchSize) {
      final end =
          (i + kUserBatchSize) > names.length ? names.length : i + kUserBatchSize;
      final chunk = names.sublist(i, end);
      try {
        final echoed = await _db
            .from('app_users')
            .update({'status': status, 'updated_at': DateTime.now().toIso8601String()})
            .inFilter('username', chunk)
            .select('username')
            .timeout(const Duration(seconds: 60));
        changed += (echoed as List).length;
      } catch (e) {
        errors.add('rows ${i + 1}-$end: ${_describeError(e)}');
      }
    }
    usersLastError = errors.isEmpty ? '' : errors.join(' | ');
    return changed;
  }

  /// Every username currently on the server, and nothing else.
  ///
  /// Also serves as the roster head-count (`.length`), which is why there is no
  /// separate count helper: `select().count()` is a postgrest API this codebase
  /// uses nowhere else, and an unverifiable second way to ask the same question
  /// is not worth the risk.
  ///
  /// The import needs to know which of its 10,000 rows already exist. Fetching
  /// full rows to answer that would pull megabytes; one text column paginates
  /// cheaply. Returns null on failure — an EMPTY set would be read as "nobody
  /// exists yet", which would turn every update into an insert and reset every
  /// password in the company.
  static Future<Set<String>?> fetchAllUsernames() async {
    if (!isReady) {
      usersLastError = _notReady;
      return null;
    }
    const page = 1000;
    final out = <String>{};
    try {
      for (var from = 0;; from += page) {
        final rows = await _db
            .from('app_users')
            .select('username')
            .order('username')
            .range(from, from + page - 1)
            .timeout(const Duration(seconds: 30));
        final list = rows as List;
        for (final r in list) {
          final u = (r as Map)['username']?.toString();
          if (u != null && u.isNotEmpty) out.add(u.toLowerCase());
        }
        if (list.length < page) break;
      }
      usersLastError = '';
      return out;
    } catch (e) {
      usersLastError = _describeError(e);
      return null;
    }
  }

  /// Search the roster by name, P.no or username. Server-side on purpose.
  ///
  /// The assign-investigator picker cannot download 10,000 users to filter them
  /// on the device — that is ~2.3 MB per keystroke-debounce and more than a
  /// browser origin's whole storage budget. Postgres does the matching, backed
  /// by the indexes in migration_bulk_users.sql.
  ///
  /// [activeOnly] defaults to true: you should not be able to hand an
  /// investigation to someone who has retired or been disabled.
  static Future<List<Map<String, dynamic>>> searchUsers(
    String query, {
    int limit = 30,
    bool activeOnly = true,
  }) async {
    if (!isReady) {
      usersLastError = _notReady;
      return [];
    }
    final q = query.trim().toLowerCase();
    try {
      var sel = _db.from('app_users').select(
          'username,name,designation,plant,department,pno,unit,grade,email,mobile,status,is_admin');
      if (q.isNotEmpty) {
        // Escape the PostgREST `or` filter separators. A comma would split the
        // expression into extra conditions and a parenthesis would unbalance it,
        // so a name containing either could produce a malformed query rather
        // than no results — worse, because it looks like a server fault.
        final safe = q.replaceAll(RegExp(r'[,()*]'), ' ').trim();
        if (safe.isNotEmpty) {
          sel = sel.or('name.ilike.%$safe%,'
              'pno.ilike.%$safe%,'
              'username.ilike.%$safe%');
        }
      }
      if (activeOnly) {
        sel = sel.not('status', 'in', '("disabled","blocked","inactive")');
      }
      final rows =
          await sel.order('name').limit(limit).timeout(const Duration(seconds: 15));
      usersLastError = '';
      return (rows as List)
          .map((r) => _userFromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      usersLastError = _describeError(e);
      return [];
    }
  }

  /// Write ONLY the credential columns for an existing user.
  ///
  /// Deliberately not upsertUser(): a password change must not carry the
  /// caller's stale copy of name/plant/designation/status back to the server
  /// and clobber edits made elsewhere.
  ///
  /// Only `password_hash` and `salt` are written — always together, never one
  /// without the other, since a hash whose salt belongs to the previous
  /// password can never be verified. There is intentionally no plaintext
  /// `password` column to clear (supabase_app_users_setup.sql drops one if it
  /// was ever created by hand), so naming it here would just error.
  ///
  /// Returns true only if a row was actually updated, so the caller can tell
  /// "changed" from "no such user".
  ///
  /// [setMustChangePassword] also writes the first-login flag: false when the
  /// account holder chose this password themselves (the act of choosing is what
  /// the flag was waiting for), true when an admin set it on their behalf (an
  /// admin knows it, so it is no more private than the P.no was). Leave it null
  /// to touch only the credential — which is what the opportunistic legacy
  /// re-hash during sign-in must do, since it reuses the password the user
  /// already had and satisfies nothing.
  static Future<bool> updateUserCredentials(
      String username, String passwordHash, String salt,
      {bool? setMustChangePassword}) async {
    if (!isReady) {
      usersLastError = _notReady;
      return false;
    }
    if (username.isEmpty) {
      usersLastError = 'username missing';
      return false;
    }
    final uname = username.trim().toLowerCase();

    Future<bool> attempt(bool withFlag) async {
      final patch = <String, dynamic>{
        'password_hash': passwordHash,
        'salt': salt,
      };
      if (withFlag) patch['must_change_password'] = setMustChangePassword;
      final echoed = await _db
          .from('app_users')
          .update(patch)
          .eq('username', uname)
          .select('username')
          .timeout(const Duration(seconds: 12));
      return (echoed as List).isNotEmpty;
    }

    try {
      final ok = await attempt(setMustChangePassword != null);
      usersLastError = '';
      return ok;
    } catch (e) {
      // must_change_password only exists once migration_bulk_users.sql has been
      // run. Rather than let a missing column block every password change on an
      // un-migrated database, drop the flag and write the credential anyway: a
      // user locked out of changing their password is a far worse failure than a
      // flag that stays raised.
      final msg = e.toString();
      if (setMustChangePassword != null &&
          msg.contains('must_change_password')) {
        try {
          final ok = await attempt(false);
          usersLastError = '';
          debugPrint('[Supabase] must_change_password column missing — '
              'credential saved without writing the flag. Run '
              'migration_bulk_users.sql.');
          return ok;
        } catch (e2) {
          usersLastError = _describeError(e2);
          return false;
        }
      }
      usersLastError = _describeError(e);
      return false;
    }
  }

  /// Whether a username is already taken on the server.
  ///
  /// Returns null when the answer is UNKNOWN (cloud off, offline, table
  /// missing). Callers must treat null as "can't confirm" rather than "free" —
  /// otherwise two people register the same username on two devices and the
  /// second upsert silently overwrites the first one's credentials.
  static Future<bool?> usernameExists(String username) async {
    if (!isReady) {
      usersLastError = _notReady;
      return null;
    }
    if (username.isEmpty) return null;
    try {
      final rows = await _db
          .from('app_users')
          .select('username')
          .eq('username', username.trim().toLowerCase())
          .limit(1)
          .timeout(const Duration(seconds: 10));
      usersLastError = '';
      return (rows as List).isNotEmpty;
    } catch (e) {
      usersLastError = _describeError(e);
      return null;
    }
  }

  /// Delete a user by username. Returns true on success.
  ///
  /// Records its failure in [usersLastError] rather than swallowing it. That
  /// silence was doing real damage: the admin panel deleted the local row and
  /// reported success while the server row survived (RLS grants no delete
  /// policy unless the migration added one), so the account reappeared on the
  /// next fetchUsers() AND the username stayed permanently un-registerable,
  /// because `usernameExists` kept answering true with no way out from the app.
  static Future<bool> deleteUser(String username) async {
    if (!isReady) {
      usersLastError = _notReady;
      return false;
    }
    if (username.isEmpty) return false;
    try {
      final echoed = await _db
          .from('app_users')
          .delete()
          .eq('username', username.trim().toLowerCase())
          .select('username')
          .timeout(const Duration(seconds: 12));
      usersLastError = '';
      // An empty echo means RLS silently dropped the delete (or the row was
      // already gone). Treat "nothing was deleted" as a failure so the caller
      // can say so instead of claiming success.
      return (echoed as List).isNotEmpty;
    } catch (e) {
      usersLastError = _describeError(e);
      return false;
    }
  }

  /// Look up one user by username (for cross-device login). Returns the app-shaped
  /// map (including password_hash/salt so the caller can verify), or null.
  static Future<Map<String, dynamic>?> getUserByUsername(String username) async {
    if (!isReady) {
      usersLastError = _notReady;
      return null;
    }
    if (username.isEmpty) return null;
    try {
      final rows = await _db
          .from('app_users')
          .select()
          // Lower-cased: rows are stored lower-case and `.eq` is case-sensitive
          // in Postgres, so "RKumar" would look like a non-existent account.
          .eq('username', username.trim().toLowerCase())
          .limit(1)
          .timeout(const Duration(seconds: 12));
      usersLastError = '';
      final list = rows as List;
      if (list.isEmpty) return null;
      return _userFromRow(Map<String, dynamic>.from(list.first as Map));
    } catch (e) {
      // Record it: a null return here previously meant either "no such user"
      // or "the request blew up", and the login screen showed the same
      // "Invalid credentials" for both.
      usersLastError = _describeError(e);
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  KNOWLEDGE BASE (knowledge_docs table)
  // ══════════════════════════════════════════════════════════════════════════

  /// Columns of `knowledge_docs` the server has rejected as unknown. Non-empty
  /// means `migration_sop_scan.sql` has not been run.
  static final Set<String> _kbMissingCols = <String>{};

  static List<String> get knowledgeSchemaGaps =>
      _kbMissingCols.toList()..sort();

  /// Last KB-write error, for diagnostics. Empty after a clean write.
  static String knowledgeLastError = '';

  /// App-key → column mapping for the SOP scan metadata. Local docs use
  /// camelCase keys; Postgres columns are snake_case.
  ///
  /// The local `id` maps to `client_id`, NOT to `id`. `knowledge_docs.id` is
  /// `bigint generated always as identity` (see SUPABASE_MIGRATION_GUIDE.md),
  /// which rejects an explicit value outright and could not hold a local id like
  /// `1723456789012-7` in any case. `client_id text unique` is added by
  /// migration_sop_scan.sql purely to give the upsert a conflict target.
  static const Map<String, String> _kbAppToDb = {
    'id':         'client_id',
    'title':      'title',
    'content':    'content',
    'source':     'source',
    'docGroup':   'doc_group',
    'sopNumber':  'sop_number',
    'clauseNo':   'clause_no',
    'pageFrom':   'page_from',
    'pageTo':     'page_to',
    'plant':      'plant',
    'uploadedBy': 'created_by',
    'verified':   'verified',
    'indexed':    'indexed',
  };

  static const Map<String, String> _kbDbToApp = {
    'client_id':  'id',
    'doc_group':  'docGroup',
    'sop_number': 'sopNumber',
    'clause_no':  'clauseNo',
    'page_from':  'pageFrom',
    'page_to':    'pageTo',
    'created_by': 'uploadedBy',
  };

  /// Fetch all KB docs. Returns [] on error.
  ///
  /// `client_id` is selected deliberately: identity used to be omitted
  /// entirely, which meant pulled docs could not be de-duplicated against local
  /// ones and [deleteKnowledgeDoc] could never be called for a synced doc,
  /// because there was no id to pass it. The table's own `id` is a bigint
  /// identity and is intentionally NOT surfaced — it is not the app's id, and
  /// exposing it would let a server row masquerade as a local one.
  static Future<List<Map<String, dynamic>>> fetchKnowledgeDocs() async {
    if (!isReady) return [];
    // Widest select first; fall back to the pre-migration column set so an
    // un-migrated server still syncs its basic docs instead of returning [].
    const wide = 'client_id, title, content, source, doc_group, sop_number, '
        'clause_no, page_from, page_to, plant, created_by, verified, indexed';
    const narrow = 'title, content, source';
    for (final cols in const [wide, narrow]) {
      try {
        final rows = await _db
            .from('knowledge_docs')
            .select(cols)
            .order('created_at', ascending: false);
        return (rows as List)
            .map((r) => _kbRowToApp(Map<String, dynamic>.from(r as Map)))
            .toList();
      } catch (e) {
        if (cols == narrow) {
          knowledgeLastError = _describeError(e);
          return [];
        }
        // Wide select failed — most likely the migration is outstanding.
        if (_missingColumnFrom(e) == null) {
          knowledgeLastError = _describeError(e);
          return [];
        }
      }
    }
    return [];
  }

  static Map<String, dynamic> _kbRowToApp(Map<String, dynamic> row) {
    final out = <String, dynamic>{};
    row.forEach((k, v) {
      if (v == null) return;
      // Never let the table's bigint `id` become the app's doc id.
      if (k == 'id') return;
      out[_kbDbToApp[k] ?? k] = v;
    });
    return out;
  }

  /// Insert or update one KB doc, keyed by `id`.
  ///
  /// This was a plain `insert` that did not send `id`, so re-pushing the
  /// knowledge base duplicated every row it already contained. Callers push
  /// deltas now, but the upsert matters independently: without a conflict target
  /// a re-sync of the same doc would still duplicate it.
  ///
  /// Carries the same schema-gap tolerance as [upsertIncident] — PostgREST
  /// rejects the ENTIRE row for one unknown column, so on a server missing
  /// `migration_sop_scan.sql` an un-guarded write would silently save nothing
  /// at all rather than saving the doc without its scan metadata.
  static Future<bool> addKnowledgeDoc(Map<String, dynamic> doc) async {
    if (!isReady) return false;

    final row = <String, dynamic>{};
    _kbAppToDb.forEach((appKey, col) {
      final v = doc[appKey];
      if (v == null) return;
      if (v is String && v.isEmpty && appKey != 'content') return;
      row[col] = v;
    });
    row['title']   ??= 'Untitled';
    row['content'] ??= '';
    row['source']  ??= 'uploaded';

    for (final c in _kbMissingCols) {
      row.remove(c);
    }

    // No client_id (a doc from before ids were pushed, or an un-migrated
    // server where the column was dropped) → plain insert; there is nothing to
    // conflict on, so it behaves exactly like the old code did.
    final maxAttempts = _kbAppToDb.length + 1;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final hasKey = (row['client_id']?.toString() ?? '').isNotEmpty;
      try {
        if (hasKey) {
          await _db
              .from('knowledge_docs')
              .upsert(row, onConflict: 'client_id');
        } else {
          await _db.from('knowledge_docs').insert(row);
        }
        knowledgeLastError = '';
        return true;
      } catch (e) {
        final missing = _missingColumnFrom(e);
        if (missing == null || !row.containsKey(missing)) {
          knowledgeLastError = _describeError(e);
          return false;
        }
        _kbMissingCols.add(missing);
        row.remove(missing);
        knowledgeLastError = 'dropped unknown column "$missing" — '
            'run migration_sop_scan.sql';
      }
    }
    return false;
  }

  /// Delete a KB doc by the app's doc id. Returns true on success.
  ///
  /// Matches on `client_id`, not `id`. The old version filtered on `id`, which
  /// is a bigint identity, so passing a local id like `1723456789012-7` matched
  /// nothing (and on a strict server raised an invalid-input error that was
  /// swallowed) — cloud deletes never actually happened. Numeric ids are also
  /// tried against `id` so rows written before `client_id` existed can still be
  /// removed.
  static Future<bool> deleteKnowledgeDoc(String id) async {
    if (!isReady || id.isEmpty) return false;
    try {
      await _db.from('knowledge_docs').delete().eq('client_id', id);
      return true;
    } catch (e) {
      if (_missingColumnFrom(e) == null) {
        knowledgeLastError = _describeError(e);
        return false;
      }
    }
    // Pre-migration server: fall back to the identity column, but only for a
    // value that can actually BE a bigint.
    if (int.tryParse(id) == null) {
      knowledgeLastError =
          'cannot delete "$id" — run migration_sop_scan.sql to add client_id';
      return false;
    }
    try {
      await _db.from('knowledge_docs').delete().eq('id', id);
      return true;
    } catch (e) {
      knowledgeLastError = _describeError(e);
      return false;
    }
  }

  /// Delete every cloud row belonging to one scanned document.
  static Future<bool> deleteKnowledgeGroup(String docGroup) async {
    if (!isReady || docGroup.isEmpty) return false;
    try {
      await _db.from('knowledge_docs').delete().eq('doc_group', docGroup);
      knowledgeLastError = '';
      return true;
    } catch (e) {
      knowledgeLastError = _describeError(e);
      return false;
    }
  }

  /// Flip `verified` for every cloud row of one scanned document.
  static Future<bool> setKnowledgeGroupVerified(
      String docGroup, bool verified) async {
    if (!isReady || docGroup.isEmpty) return false;
    try {
      await _db
          .from('knowledge_docs')
          .update({'verified': verified})
          .eq('doc_group', docGroup);
      knowledgeLastError = '';
      return true;
    } catch (e) {
      knowledgeLastError = _describeError(e);
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

  // ══════════════════════════════════════════════════════════════════════════
  //  AI RUN TELEMETRY  (table `ai_runs`, see supabase_ai_runs_setup.sql)
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ⚠ Every key here must exist as a column in ai_runs. PostgREST rejects the
  // WHOLE row if it mentions one unknown column, so adding a key below without
  // the matching ALTER TABLE stops ALL telemetry reaching the server — silently,
  // because AiRunLog deliberately swallows its own errors.
  static const Map<String, String> _runAppToDb = {
    'id': 'id',
    'runType': 'run_type',
    'outcome': 'outcome',
    'failReason': 'fail_reason',
    'provider': 'provider',
    'model': 'model',
    'durationMs': 'duration_ms',
    'hazardCount': 'hazard_count',
    'confidence': 'confidence',
    'imageHash': 'image_hash',
    'plant': 'plant',
    'dept': 'dept',
    'userName': 'user_name',
    'userPno': 'user_pno',
    'appVersion': 'app_version',
    'platform': 'platform',
    'createdAt': 'created_at',
  };
  static final Map<String, String> _runDbToApp = {
    for (final e in _runAppToDb.entries) e.value: e.key,
  };

  /// Last failure from an ai_runs read/write, or '' when the last call worked.
  ///
  /// WHY THIS EXISTS: both methods below used to swallow their errors and return
  /// `[]` / `false`. That made a MISSING `ai_runs` TABLE indistinguishable from
  /// "nobody has run a scan yet" — the dashboard showed a clean set of zeros
  /// while every single row was silently stranded on one device. The AI
  /// Performance module now reads this and says so out loud.
  static String aiRunsLastError = '';

  /// Supabase is switched off or unconfigured in this build. Distinct from an
  /// error: there is no cloud to reach, so the dashboard should say "local only
  /// by design" rather than raise an alarm and offer a Retry that cannot work.
  static bool aiRunsCloudDisabled = false;

  /// True when the failure looks like "the table/columns do not exist yet",
  /// i.e. supabase_ai_runs_setup.sql was never run. PostgREST reports this as
  /// 42P01 (undefined_table) or PGRST205 (table not found in schema cache).
  static bool get aiRunsSchemaMissing {
    final e = aiRunsLastError.toLowerCase();
    return e.contains('42p01') ||
        e.contains('pgrst205') ||
        e.contains('does not exist') ||
        e.contains('could not find the table');
  }

  static String _describeError(Object e) {
    if (e is PostgrestException) {
      final code = (e.code ?? '').isEmpty ? '' : '${e.code}: ';
      return '$code${e.message}';
    }
    return e.toString();
  }

  /// Fetch AI runs, newest first.
  ///
  /// Capped at 5000 rows: this is append-only telemetry that grows with every
  /// scan across every device, and an unbounded select would eventually stall
  /// the admin panel. The dashboard only ever reports on recent windows.
  static Future<List<Map<String, dynamic>>> fetchAiRuns({int limit = 5000}) async {
    if (!isReady) {
      aiRunsCloudDisabled = true;
      aiRunsLastError = '';
      return [];
    }
    aiRunsCloudDisabled = false;
    try {
      final rows = await _db
          .from('ai_runs')
          .select()
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 8));
      aiRunsLastError = '';
      return (rows as List)
          .map((r) => _runFromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    } catch (e) {
      // Missing table / offline / timeout — the dashboard still falls back to
      // the local ring buffer, but it now knows WHY it had to.
      aiRunsLastError = _describeError(e);
      return [];
    }
  }

  /// Insert or update one AI run record (keyed by id).
  static Future<bool> upsertAiRun(Map<String, dynamic> run) async {
    final id = run['id']?.toString() ?? '';
    if (id.isEmpty) return false;
    final confirmed = await upsertAiRuns([run]);
    return confirmed.contains(id);
  }

  /// Insert or update many AI run records in one round trip.
  ///
  /// Used by AiRunLog.flushUnsynced() to drain the backlog that builds up while
  /// the table is missing or the device is offline.
  ///
  /// Returns the ids the SERVER echoed back, not the ids we sent. That
  /// distinction is the whole reliability story here: the caller flips a local
  /// "synced" flag based on this result, and inferring success purely from "no
  /// exception was thrown" would let it mark rows as safely stored when they
  /// were not, which is exactly the class of silent loss this fix exists to end.
  /// On failure the set is empty and the reason is in [aiRunsLastError].
  static Future<Set<String>> upsertAiRuns(List<Map<String, dynamic>> runs) async {
    if (runs.isEmpty) return <String>{};
    if (!isReady) {
      aiRunsCloudDisabled = true;
      aiRunsLastError = '';
      return <String>{};
    }
    aiRunsCloudDisabled = false;
    try {
      final rows = <Map<String, dynamic>>[];
      for (final run in runs) {
        final row = <String, dynamic>{};
        _runAppToDb.forEach((appKey, dbCol) {
          if (!run.containsKey(appKey)) return;
          row[dbCol] = run[appKey];
        });
        // Local-only bookkeeping keys (e.g. AiRunLog's 'synced') are dropped by
        // the map above, which matters: PostgREST rejects the WHOLE batch for
        // one unknown column.
        if ((row['id']?.toString() ?? '').isEmpty) continue;
        rows.add(row);
      }
      // Nothing sendable is not a server failure — leave aiRunsLastError alone
      // so the caller can tell "bad input, skip it" from "cloud is down, stop".
      if (rows.isEmpty) return <String>{};

      final echoed = await _db
          .from('ai_runs')
          .upsert(rows, onConflict: 'id')
          .select('id')
          .timeout(const Duration(seconds: 12));
      aiRunsLastError = '';
      return (echoed as List)
          .map((r) => (Map<String, dynamic>.from(r as Map)['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (e) {
      aiRunsLastError = _describeError(e);
      return <String>{};
    }
  }

  static Map<String, dynamic> _runFromRow(Map<String, dynamic> row) {
    final r = <String, dynamic>{};
    row.forEach((dbCol, v) {
      final appKey = _runDbToApp[dbCol];
      if (appKey != null) r[appKey] = v;
    });
    return r;
  }
}
