// lib/services/auth_service.dart
//
// SINGLE AUTHORITY for credentials in Safety Lens.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHY THIS FILE EXISTS
// ─────────────────────────────────────────────────────────────────────────────
// Before this service, three different code paths each invented their own
// password format and wrote it into the same `password_hash` column:
//
//   • LocalDB.register()      → salted SHA-256 (CryptoUtils) + `salt`
//   • login_screen._register  → _simpleHash(), a 32-bit UNSALTED non-crypto
//                               hash copied from the old Apps Script backend,
//                               and it never sent `salt` at all
//   • admin "reset password"  → PLAINTEXT in a `password` key that the
//                               Supabase column map silently dropped
//
// Consequences, all of which were real and observable:
//   1. Register on the web, then log in on the phone → "Invalid credentials",
//      because device B verified a salted hash against an unsalted one.
//   2. Admin resets a password → nothing reaches Supabase (the `password` key
//      isn't in the column map), AND the old passwordHash is left in place, so
//      the OLD password keeps working and the new one never does.
//   3. Cross-device login compared the *transported* hash to the *stored*
//      hash. When those are equal, the hash IS the password: anyone who can
//      read the row (and `app_users` was world-readable) can authenticate.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE ONE FORMAT
// ─────────────────────────────────────────────────────────────────────────────
//   salt          = 16 random bytes, hex (CryptoUtils.generateSalt)
//   passwordHash  = sha256(salt + password), hex
//
// Both are always written together, everywhere. A row with a hash but no salt
// is by definition a legacy row, and `_verify()` upgrades it in place the next
// time that user successfully logs in.
//
// The plaintext password never leaves this file's parameters — it is hashed
// before it touches LocalDB, Supabase, or a log line.
//
// ─────────────────────────────────────────────────────────────────────────────
// KNOWN REMAINING RISK — needs a Supabase dashboard change, not a code change
// ─────────────────────────────────────────────────────────────────────────────
// `app_users` currently has a policy equivalent to `for all to anon using
// (true)`, so the anon key can read every row including password_hash and
// salt. Salted SHA-256 is fast to brute-force offline. Until that policy is
// tightened (see supabase_app_users_setup.sql), treat these hashes as
// recoverable. The SQL file added alongside this service explains the fix.
//
// ignore_for_file: avoid_print

import 'package:flutter/foundation.dart' show debugPrint;

import 'crypto_utils.dart';
import 'local_db.dart';
import 'supabase_config.dart';
import 'supabase_service.dart';
import 'sync_service.dart';
import 'auth_token_service.dart';
import 'validators.dart';

/// Outcome of an auth operation. Carries a reason so the UI can say something
/// truthful instead of collapsing every failure into "Invalid credentials".
enum AuthFailure {
  none,

  /// Username/password didn't match a known account.
  badCredentials,

  /// Account exists but an admin disabled or blocked it.
  accountDisabled,

  /// No account with that username, locally or on the server.
  noSuchUser,

  /// Username already taken.
  usernameTaken,

  /// We could not reach the backend to confirm something we must confirm
  /// (e.g. username uniqueness, or a password write). The operation was NOT
  /// completed — retrying when online is the right move.
  offline,

  /// The backend answered, but with an error (missing table, RLS denial, …).
  backendError,

  /// The identity answers given for a self-service reset didn't match.
  identityMismatch,

  /// Caller passed something invalid (empty username, weak password, …).
  invalidInput,
}

class AuthResult {
  final bool ok;
  final AuthFailure failure;

  /// The credential-free user map on success.
  final Map<String, dynamic>? user;

  /// Human-readable detail, safe to show. Never contains a password.
  final String message;

  const AuthResult._(this.ok, this.failure, this.user, this.message);

  factory AuthResult.success(Map<String, dynamic>? user, [String msg = '']) =>
      AuthResult._(true, AuthFailure.none, user, msg);

  factory AuthResult.fail(AuthFailure f, String msg) =>
      AuthResult._(false, f, null, msg);

  @override
  String toString() => 'AuthResult(ok: $ok, failure: $failure, msg: $message)';
}

class AuthService {
  AuthService._();

  // ═════════════════════════════════════════════════════════════════════════
  //  CREDENTIAL PRIMITIVES
  // ═════════════════════════════════════════════════════════════════════════

  /// Minimum length. Delegated to Validators rather than duplicated, so a form
  /// can't accept a password that this service then rejects (or vice versa).
  static int get minPasswordLength => Validators.minPasswordLength;

  /// Produce a fresh {passwordHash, salt} pair. Always use this — never write
  /// a hash without its salt.
  static Map<String, String> _newCredential(String password) {
    final salt = CryptoUtils.generateSalt();
    return {
      'salt': salt,
      'passwordHash': CryptoUtils.hashPassword(password, salt),
    };
  }

  /// Strip every credential field from a user map before it is handed to the
  /// UI or stored as the "current user". Centralised because three call sites
  /// each remembered a different subset.
  static Map<String, dynamic> sanitize(Map<String, dynamic> u) =>
      Map<String, dynamic>.from(u)
        ..remove('password')
        ..remove('passwordHash')
        ..remove('salt')
        ..remove('password_hash');

  /// Legacy Apps Script hash. Retained ONLY to let accounts created by the old
  /// code log in once, at which point they are upgraded to the salted format.
  /// Never used for new writes.
  ///
  /// Mirrors:
  ///   h = ((h << 5) - h) + charCode; h = h & h;   // 32-bit signed
  static String legacySimpleHash(String str) {
    int h = 0;
    for (int i = 0; i < str.length; i++) {
      h = ((h << 5) - h) + str.codeUnitAt(i);
      h = (h & 0xFFFFFFFF).toSigned(32);
    }
    if (h < 0) return '-${((-h) & 0xFFFFFFFF).toRadixString(36)}';
    return h.toRadixString(36);
  }

  /// Verify [password] against a stored user record, tolerating every legacy
  /// format we have ever written. Returns the format that matched, or null.
  ///
  /// Order matters: the modern salted check runs first so a legacy fallback can
  /// never shadow a properly-hashed credential.
  static String? _matchFormat(Map<String, dynamic> u, String password) {
    final salt = u['salt']?.toString() ?? '';
    final hash = u['passwordHash']?.toString() ?? '';

    // 1. Current format.
    if (salt.isNotEmpty && hash.isNotEmpty) {
      if (CryptoUtils.verifyPassword(password, salt, hash)) return 'salted';
      // A salted credential that doesn't match is a genuine wrong password.
      // Do NOT fall through to the weaker checks below — that would let an
      // attacker who knows the legacy hash bypass a rehashed account.
      return null;
    }

    // 2. Legacy: unsalted Apps Script hash in password_hash.
    if (hash.isNotEmpty && salt.isEmpty) {
      if (hash == legacySimpleHash(password)) return 'legacy-simple';
      // Historic bug: LocalDB.signIn compared the stored hash to the RAW typed
      // password, meaning anyone who could read the hash could log in with it
      // verbatim. That comparison is deliberately NOT reproduced here.
    }

    // 3. Legacy: plaintext in `password` (admin-created accounts).
    final plain = u['password']?.toString() ?? '';
    if (plain.isNotEmpty && plain == password) return 'legacy-plain';

    return null;
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  SIGN IN
  // ═════════════════════════════════════════════════════════════════════════

  /// Authenticate, offline-first.
  ///
  /// 1. Local store (instant, works with no network).
  /// 2. Supabase `app_users` — this is what makes "registered on the web, first
  ///    login on the phone" work. The row's OWN salt is used to verify, so no
  ///    hash is ever transported as a credential.
  /// 3. Legacy Apps Script backend, only when Supabase is off.
  ///
  /// On success the account is cached locally in the canonical format so the
  /// next login works offline, and any legacy credential is upgraded.
  /// When [startSession] is false the credentials are checked but the stored
  /// "current user" is left alone. Used by the Admin panel's gate, which is
  /// re-verifying an identity rather than starting a new app session — logging
  /// into the admin screen must not silently swap out who the app thinks is
  /// signed in.
  static Future<AuthResult> signIn(String username, String password,
      {bool startSession = true}) async {
    final uname = username.trim();
    if (uname.isEmpty) {
      return AuthResult.fail(AuthFailure.invalidInput, 'Enter your username.');
    }
    if (password.isEmpty) {
      return AuthResult.fail(AuthFailure.invalidInput, 'Enter your password.');
    }

    // ── 1. LOCAL ──────────────────────────────────────────────────────────
    final local = await _findLocal(uname);
    if (local != null) {
      if (_isBlocked(local)) {
        return AuthResult.fail(AuthFailure.accountDisabled,
            'This account has been disabled. Contact your admin.');
      }
      final format = _matchFormat(local, password);
      if (format != null) {
        if (format != 'salted') {
          // Upgrade in place, and push the upgrade to the server so other
          // devices stop relying on the weak format too.
          await _persistCredential(local['username']?.toString() ?? uname,
              password, pushRemote: true);
          debugPrint('[Auth] upgraded $uname from $format to salted');
        }
        final safe = sanitize(local);
        if (startSession) {
          await LocalDB.setCurrentUser(safe);
          await _issueLocalToken(safe);
        }
        return AuthResult.success(safe);
      }
      // Wrong password for a known local account. Still fall through: the
      // server may hold a NEWER password (changed on another device) than this
      // device's stale cache.
    }

    // ── 2. SUPABASE ───────────────────────────────────────────────────────
    if (SupabaseConfig.enabled) {
      final remote = await SupabaseService.getUserByUsername(uname);
      if (remote != null) {
        if (_isBlocked(remote)) {
          return AuthResult.fail(AuthFailure.accountDisabled,
              'This account has been disabled. Contact your admin.');
        }
        final format = _matchFormat(remote, password);
        if (format != null) {
          // Cache locally in the CANONICAL format regardless of which format
          // the server row used, so offline login works from now on.
          final cred = _newCredential(password);
          final cached = Map<String, dynamic>.from(remote)
            ..remove('password')
            ..['salt'] = cred['salt']
            ..['passwordHash'] = cred['passwordHash']
            ..['username'] = remote['username'] ?? uname
            ..['status'] = remote['status'] ?? 'active';
          await LocalDB.upsertUser(cached);

          if (format != 'salted') {
            // Rewrite the server row too, so device C doesn't repeat this.
            await SupabaseService.updateUserCredentials(
                uname, cred['passwordHash']!, cred['salt']!);
            debugPrint('[Auth] upgraded server row for $uname from $format');
          }

          final safe = sanitize(cached);
          if (startSession) {
            await LocalDB.setCurrentUser(safe);
            await _issueLocalToken(safe);
          }
          return AuthResult.success(safe);
        }
        return AuthResult.fail(
            AuthFailure.badCredentials, 'Incorrect password.');
      }

      // No row came back. Distinguish "no such user" from "the query failed",
      // because telling someone their password is wrong when the table is
      // missing sends them down a very long wrong path.
      if (SupabaseService.usersLastError.isNotEmpty) {
        debugPrint('[Auth] signIn backend error: '
            '${SupabaseService.usersLastError}');
        if (local != null) {
          return AuthResult.fail(
              AuthFailure.badCredentials, 'Incorrect password.');
        }
        return AuthResult.fail(
            AuthFailure.backendError,
            SupabaseService.usersSchemaMissing
                ? 'User accounts are not set up on the server yet. '
                    'Ask your admin to run the app_users migration.'
                : 'Could not reach the account server. Check your connection '
                    'and try again.');
      }

      if (local != null) {
        return AuthResult.fail(
            AuthFailure.badCredentials, 'Incorrect password.');
      }
      return AuthResult.fail(AuthFailure.noSuchUser,
          'No account found for "$uname". Register first, or check the spelling.');
    }

    // ── 3. LEGACY APPS SCRIPT ─────────────────────────────────────────────
    // Only reachable when Supabase is disabled. Uses the old transported-hash
    // protocol because that is what that backend understands.
    try {
      final remote =
          await SyncService.loginOnline(uname, legacySimpleHash(password));
      if (remote != null) {
        final cred = _newCredential(password);
        final cached = Map<String, dynamic>.from(remote)
          ..remove('password')
          ..['username'] = remote['username'] ?? uname
          ..['status'] = remote['status'] ?? 'active'
          ..['salt'] = cred['salt']
          ..['passwordHash'] = cred['passwordHash'];
        await LocalDB.upsertUser(cached);
        final safe = sanitize(cached);
        if (startSession) await LocalDB.setCurrentUser(safe);
        return AuthResult.success(safe);
      }
    } catch (e) {
      debugPrint('[Auth] legacy loginOnline failed: $e');
    }

    if (local != null) {
      return AuthResult.fail(AuthFailure.badCredentials, 'Incorrect password.');
    }
    return AuthResult.fail(AuthFailure.noSuchUser,
        'No account found for "$uname". Register first, or check the spelling.');
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  REGISTER
  // ═════════════════════════════════════════════════════════════════════════

  /// Create an account.
  ///
  /// [userData] carries the profile fields (name, username, designation, plant,
  /// pno, …). The password is passed separately so a plaintext value is never
  /// sitting in a map that might get logged or persisted by accident.
  ///
  /// Uniqueness is checked against the SERVER as well as locally. Previously
  /// only the local list was checked, so two devices could each create "rkumar"
  /// and the second `upsert(onConflict: 'username')` overwrote the first
  /// person's credentials — locking them out of their own account.
  /// [signIn] controls whether the new account becomes the ACTIVE session.
  /// True for self-registration on the login screen; must be false when an
  /// admin creates an account for someone else, otherwise the admin's own
  /// session is silently replaced by the user they just created.
  static Future<AuthResult> register(
      Map<String, dynamic> userData, String password,
      {bool signIn = true}) async {
    final uname = (userData['username']?.toString() ?? '').trim().toLowerCase();
    if (uname.isEmpty) {
      return AuthResult.fail(AuthFailure.invalidInput, 'Choose a username.');
    }
    if (password.length < minPasswordLength) {
      return AuthResult.fail(AuthFailure.invalidInput,
          'Password must be at least $minPasswordLength characters.');
    }

    // Local collision.
    final existingLocal = await _findLocal(uname);
    if (existingLocal != null) {
      return AuthResult.fail(AuthFailure.usernameTaken,
          'The username "$uname" is already taken.');
    }

    // Server collision. null = unknown; we must not guess "free".
    if (SupabaseConfig.enabled) {
      final taken = await SupabaseService.usernameExists(uname);
      if (taken == true) {
        return AuthResult.fail(AuthFailure.usernameTaken,
            'The username "$uname" is already registered. '
            'Try logging in, or pick a different one.');
      }
      if (taken == null) {
        final err = SupabaseService.usersLastError;
        debugPrint('[Auth] register: uniqueness unknown — $err');
        return AuthResult.fail(
            AuthFailure.offline,
            SupabaseService.usersSchemaMissing
                ? 'User accounts are not set up on the server yet. '
                    'Ask your admin to run the app_users migration.'
                : 'Cannot reach the server to confirm this username is free. '
                    'Connect to the internet and try again.');
      }
    }

    final cred = _newCredential(password);
    final record = Map<String, dynamic>.from(userData)
      ..remove('password')
      ..['username'] = uname
      ..['status'] = userData['status'] ?? 'active'
      ..['salt'] = cred['salt']
      ..['passwordHash'] = cred['passwordHash'];

    // Write to the server FIRST when it's available. If the account can't be
    // created centrally, creating it locally would produce an account that
    // works on exactly one device and silently isn't in the admin panel.
    if (SupabaseConfig.enabled) {
      final pushed = await SupabaseService.upsertUser(record);
      if (!pushed) {
        final err = SupabaseService.usersLastError;
        debugPrint('[Auth] register: server write failed — $err');
        return AuthResult.fail(
            AuthFailure.backendError,
            SupabaseService.usersSchemaMissing
                ? 'User accounts are not set up on the server yet. '
                    'Ask your admin to run the app_users migration.'
                : 'Could not create your account on the server. '
                    'Check your connection and try again.');
      }
    } else {
      // Legacy backend: best-effort, with a retry queue behind it.
      final push = Map<String, dynamic>.from(record)
        ..['passwordHash'] = legacySimpleHash(password);
      SyncService.registerOnline(push).then((okRemote) {
        if (!okRemote) SyncService.pushUserReliable(push);
      }).catchError((_) => SyncService.pushUserReliable(push));
    }

    await LocalDB.upsertUser(record);
    final safe = sanitize(record);
    if (signIn) {
      await LocalDB.setCurrentUser(safe);
      await _issueLocalToken(safe);
    }
    return AuthResult.success(safe, 'Account created.');
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  PASSWORD CHANGES
  // ═════════════════════════════════════════════════════════════════════════

  /// Change your own password. Requires the current one.
  static Future<AuthResult> changePassword({
    required String username,
    required String currentPassword,
    required String newPassword,
  }) async {
    final uname = username.trim();
    if (newPassword.length < minPasswordLength) {
      return AuthResult.fail(AuthFailure.invalidInput,
          'New password must be at least $minPasswordLength characters.');
    }
    if (newPassword == currentPassword) {
      return AuthResult.fail(AuthFailure.invalidInput,
          'New password must be different from the current one.');
    }

    // Verify against whichever store knows this account.
    Map<String, dynamic>? record = await _findLocal(uname);
    var matched = record != null && _matchFormat(record, currentPassword) != null;

    if (!matched && SupabaseConfig.enabled) {
      final remote = await SupabaseService.getUserByUsername(uname);
      if (remote != null && _matchFormat(remote, currentPassword) != null) {
        record = remote;
        matched = true;
      }
    }
    if (!matched) {
      return AuthResult.fail(
          AuthFailure.badCredentials, 'Your current password is incorrect.');
    }

    return _persistCredential(uname, newPassword, pushRemote: true);
  }

  /// Self-service reset: the user proves who they are, then CHOOSES their own
  /// password.
  ///
  /// Replaces the old flow, which reset everyone to the hardcoded `sail@123`,
  /// wrote it only to the local device, and asked for no proof of identity at
  /// all — any visitor to the login screen could reset any account they could
  /// name, and the "new" password was a value printed in the source code.
  ///
  /// [proof] must match a non-empty identifying field on the stored record —
  /// employee number (PNO), registered mobile, or email. This is deliberately
  /// modest: it's what the app actually holds. It is a speed bump, not identity
  /// verification, which is why an admin reset still exists as the strong path.
  static Future<AuthResult> resetPasswordWithProof({
    required String username,
    required String proof,
    required String newPassword,
  }) async {
    final uname = username.trim();
    final answer = proof.trim().toLowerCase();

    if (uname.isEmpty) {
      return AuthResult.fail(AuthFailure.invalidInput, 'Enter your username.');
    }
    if (answer.isEmpty) {
      return AuthResult.fail(AuthFailure.invalidInput,
          'Enter your employee number, mobile, or email to confirm it\'s you.');
    }
    if (newPassword.length < minPasswordLength) {
      return AuthResult.fail(AuthFailure.invalidInput,
          'Password must be at least $minPasswordLength characters.');
    }

    // Prefer the server record: it's authoritative, and a local-only check
    // would let someone reset an account using a stale cached PNO.
    Map<String, dynamic>? record;
    if (SupabaseConfig.enabled) {
      record = await SupabaseService.getUserByUsername(uname);
      if (record == null && SupabaseService.usersLastError.isNotEmpty) {
        return AuthResult.fail(
            AuthFailure.offline,
            'Could not reach the account server, so the reset was not saved. '
            'Try again when you have a connection.');
      }
    }
    record ??= await _findLocal(uname);

    if (record == null) {
      return AuthResult.fail(AuthFailure.noSuchUser,
          'No account found for "$uname". Check the spelling or contact your admin.');
    }
    if (_isBlocked(record)) {
      return AuthResult.fail(AuthFailure.accountDisabled,
          'This account is disabled. Contact your admin.');
    }

    final candidates = <String>[
      record['pno']?.toString() ?? '',
      record['mobile']?.toString() ?? '',
      record['email']?.toString() ?? '',
    ].where((s) => s.trim().isNotEmpty).map((s) => s.trim().toLowerCase()).toList();

    if (candidates.isEmpty) {
      // Nothing on file to check against — refuse rather than wave it through.
      return AuthResult.fail(
          AuthFailure.identityMismatch,
          'This account has no employee number, mobile, or email on file, '
          'so it can only be reset by an admin.');
    }
    if (!candidates.contains(answer)) {
      return AuthResult.fail(AuthFailure.identityMismatch,
          'That doesn\'t match our records for "$uname".');
    }

    return _persistCredential(uname, newPassword, pushRemote: true);
  }

  /// Admin-initiated reset. No current password required, but the new one is
  /// hashed and written to BOTH stores, and any legacy plaintext/hash is
  /// cleared so the previous password stops working.
  static Future<AuthResult> adminSetPassword(
      String username, String newPassword) async {
    final uname = username.trim();
    if (uname.isEmpty) {
      return AuthResult.fail(AuthFailure.invalidInput, 'Missing username.');
    }
    if (newPassword.length < minPasswordLength) {
      return AuthResult.fail(AuthFailure.invalidInput,
          'Password must be at least $minPasswordLength characters.');
    }
    return _persistCredential(uname, newPassword,
        pushRemote: true, requireRemote: false);
  }

  /// The ONE place a credential is written. Local always; server too when
  /// [pushRemote].
  ///
  /// When [requireRemote] is true (the default for user-driven changes) a
  /// failed server write fails the whole operation. Saving locally only would
  /// be worse than failing: the user would believe their password changed, it
  /// would work on this device, and it would keep rejecting them everywhere
  /// else with no explanation.
  static Future<AuthResult> _persistCredential(
    String username,
    String newPassword, {
    bool pushRemote = true,
    bool requireRemote = true,
  }) async {
    final cred = _newCredential(newPassword);

    if (pushRemote && SupabaseConfig.enabled) {
      var ok = await SupabaseService.updateUserCredentials(
          username, cred['passwordHash']!, cred['salt']!);

      if (!ok && SupabaseService.usersLastError.isEmpty) {
        // Update touched zero rows: the account exists locally but was never
        // pushed. Create it server-side so the change is durable.
        final local = await _findLocal(username);
        if (local != null) {
          final row = Map<String, dynamic>.from(local)
            ..remove('password')
            ..['username'] = username
            ..['salt'] = cred['salt']
            ..['passwordHash'] = cred['passwordHash'];
          ok = await SupabaseService.upsertUser(row);
        }
      }

      if (!ok && requireRemote) {
        final err = SupabaseService.usersLastError;
        debugPrint('[Auth] credential write failed for $username — $err');
        return AuthResult.fail(
            AuthFailure.backendError,
            SupabaseService.usersSchemaMissing
                ? 'User accounts are not set up on the server yet. '
                    'Ask your admin to run the app_users migration.'
                : 'Could not save the new password to the server, so nothing '
                    'was changed. Check your connection and try again.');
      }
      if (!ok) {
        debugPrint('[Auth] remote credential write failed for $username; '
            'queueing local-only change');
      }
    }

    // Local write. Explicitly clears the legacy plaintext key — LocalDB's
    // upsert MERGES, so a stale `password` would otherwise survive and keep
    // authenticating the old value via the legacy-plain path.
    final local = await _findLocal(username);
    final record = <String, dynamic>{
      ...?local,
      'username': local?['username']?.toString() ?? username,
      'salt': cred['salt'],
      'passwordHash': cred['passwordHash'],
    }..remove('password');
    await LocalDB.upsertUser(record);
    await LocalDB.clearLegacyPassword(username);

    return AuthResult.success(sanitize(record), 'Password updated.');
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═════════════════════════════════════════════════════════════════════════

  /// Look up a user in either local bucket, matching username OR email,
  /// case-insensitively. Usernames were stored inconsistently (registration
  /// lower-cased them in the admin panel but not on the login screen), so a
  /// case-sensitive match locked people out of their own accounts.
  static Future<Map<String, dynamic>?> _findLocal(String identifier) async {
    final id = identifier.trim().toLowerCase();
    if (id.isEmpty) return null;

    bool matches(Map<String, dynamic> u) {
      final uname = (u['username']?.toString() ?? '').trim().toLowerCase();
      final email = (u['email']?.toString() ?? '').trim().toLowerCase();
      return uname == id || (email.isNotEmpty && email == id);
    }

    for (final u in await LocalDB.getUsers()) {
      if (matches(u)) return u;
    }
    for (final u in await LocalDB.getCachedUsers()) {
      if (matches(u)) return u;
    }
    return null;
  }

  static bool _isBlocked(Map<String, dynamic> u) {
    final s = (u['status']?.toString().toLowerCase() ?? 'active').trim();
    return s == 'disabled' || s == 'blocked' || s == 'inactive';
  }

  /// Local fallback session token so authenticated API calls work even when
  /// the server didn't issue one. Non-fatal if it fails.
  static Future<void> _issueLocalToken(Map<String, dynamic> safeUser) async {
    try {
      final id = safeUser['pno']?.toString().isNotEmpty == true
          ? safeUser['pno'].toString()
          : safeUser['username']?.toString() ?? '';
      if (id.isNotEmpty) await AuthTokenService.generateToken(id);
    } catch (e) {
      debugPrint('[Auth] local token generation failed (ignored): $e');
    }
  }

  /// Is this username free? For live feedback on the registration form.
  /// Returns null when it can't be determined.
  static Future<bool?> isUsernameAvailable(String username) async {
    final uname = username.trim().toLowerCase();
    if (uname.isEmpty) return null;
    if (await _findLocal(uname) != null) return false;
    if (!SupabaseConfig.enabled) return null;
    final taken = await SupabaseService.usernameExists(uname);
    return taken == null ? null : !taken;
  }
}
