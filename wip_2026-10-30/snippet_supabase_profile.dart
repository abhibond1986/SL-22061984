  // ── SELF-SERVICE PROFILE (My Profile screen, 2026-10-30) ─────────────────

  /// Fields an account holder may edit about themselves. Name, P.no, grade,
  /// plant and dates stay with the HR import and the admin.
  static const List<String> kSelfEditableFields = [
    'mobile', 'email', 'designation', 'department', 'unit',
  ];

  /// True after [updateOwnProfile] saved the values but the server has no
  /// self_edited_fields column yet (migration_profile_self_edit.sql not run),
  /// so the next quarterly import may overwrite them.
  static bool selfEditUnprotected = false;

  /// Save the account holder's own edits. [changed] is app-keyed and limited
  /// to [kSelfEditableFields]; [editedFields] is the full set this user has
  /// ever edited (stored so the import keeps them). An UPDATE of just these
  /// columns, never an upsert of the whole row, so a stale device copy cannot
  /// revert anything else.
  static Future<bool> updateOwnProfile(String username,
      Map<String, dynamic> changed, Set<String> editedFields) async {
    selfEditUnprotected = false;
    if (!isReady) {
      usersLastError = _notReady;
      return false;
    }
    final uname = username.trim().toLowerCase();
    if (uname.isEmpty) {
      usersLastError = 'username missing';
      return false;
    }
    final patch = <String, dynamic>{};
    changed.forEach((k, v) {
      if (kSelfEditableFields.contains(k)) {
        patch[_userAppToDb[k]!] = v?.toString().trim() ?? '';
      }
    });
    if (patch.isEmpty) return true;
    patch['updated_at'] = DateTime.now().toIso8601String();

    Future<bool> attempt(bool withMarker) async {
      final body = Map<String, dynamic>.from(patch);
      if (withMarker) {
        body['self_edited_fields'] = (editedFields.toList()..sort()).join(',');
        body['self_edited_at'] = DateTime.now().toIso8601String();
      }
      final echoed = await _db
          .from('app_users')
          .update(body)
          .eq('username', uname)
          .select('username')
          .timeout(const Duration(seconds: 12));
      return (echoed as List).isNotEmpty;
    }

    try {
      final ok = await attempt(true);
      usersLastError = ok ? '' : 'account not found on the server';
      return ok;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('self_edited')) {
        // Column missing: save the values anyway; flag that they are not yet
        // protected from the next import.
        try {
          final ok = await attempt(false);
          selfEditUnprotected = ok;
          usersLastError = ok ? '' : 'account not found on the server';
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

  /// Current server values of the self-edited fields, for every account that
  /// has any. Used by the quarterly import so it does not overwrite them.
  /// Returns {} if the column does not exist yet; null on any other failure
  /// (the caller must then not pretend the edits are protected).
  static Future<Map<String, Map<String, dynamic>>?> fetchSelfEditedProfiles()
      async {
    if (!isReady) {
      usersLastError = _notReady;
      return null;
    }
    const page = 1000;
    final out = <String, Map<String, dynamic>>{};
    try {
      for (var from = 0;; from += page) {
        final rows = await _db
            .from('app_users')
            .select('username,self_edited_fields,mobile,email,designation,'
                'department,unit')
            .not('self_edited_fields', 'is', null)
            .neq('self_edited_fields', '')
            .order('username')
            .range(from, from + page - 1)
            .timeout(const Duration(seconds: 30));
        final list = rows as List;
        for (final r in list) {
          final m = Map<String, dynamic>.from(r as Map);
          final u = m['username']?.toString().toLowerCase() ?? '';
          final fields = (m['self_edited_fields']?.toString() ?? '')
              .split(',')
              .map((f) => f.trim())
              .where(kSelfEditableFields.contains);
          if (u.isEmpty) continue;
          final kept = <String, dynamic>{
            for (final f in fields) f: m[_userAppToDb[f]!],
          };
          if (kept.isNotEmpty) out[u] = kept;
        }
        if (list.length < page) break;
      }
      usersLastError = '';
      return out;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('self_edited')) return <String, Map<String, dynamic>>{};
      usersLastError = _describeError(e);
      return null;
    }
  }

