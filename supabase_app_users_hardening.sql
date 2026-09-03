-- ═══════════════════════════════════════════════════════════════════════════
--  SAIL Safety Lens — app_users HARDENING  (written 2026-09-03)
--
--  Run in the Supabase dashboard: SQL Editor → New query → paste → Run.
--  Idempotent (create or replace / drop-then-create), safe to re-run.
--
--  WHAT IT FIXES
--  Login does not use Supabase Auth; it reads a salted SHA-256 hash out of the
--  `app_users` table with the ANON key. That key is a compile-time constant in
--  supabase_config.dart, and this repository is public, so today anyone can
--  read every user's `password_hash` and `salt` — the whole roster, in one
--  request. Salted SHA-256 is fast to attack offline, so a short or reused
--  password falls quickly. The permissive read policy in STEP 3 of
--  supabase_app_users_setup.sql is what allows this, and that file's own
--  "SECURITY POSTURE" note called it out; this file is the promised fix.
--
--  HOW IT FIXES IT
--  Verification moves INTO the database. A `security definer` function compares
--  the hash server-side, so the anon key no longer needs to read credentials —
--  and then the read policy is closed.
--
--  ⚠ RUN ORDER MATTERS. Sections 1 and 2 are ADDITIVE: they add functions and
--  break nothing, so run them whenever you like. Section 3 REVOKES reads and
--  will break login on every device until the client is changed to call
--  verify_login(). Do not run section 3 until the client change ships — the
--  Dart work needed is listed at the bottom of this file.
-- ═══════════════════════════════════════════════════════════════════════════

-- Needed for digest(). Supabase projects usually have it, but be explicit.
create extension if not exists pgcrypto;


-- ── SECTION 1 : server-side login (ADDITIVE — safe to run now) ─────────────
--
-- Takes the PLAINTEXT password over TLS and hashes it inside the database, so
-- the salt never has to leave. Returns nothing at all on a bad password, which
-- is what makes this a verification function rather than a lookup.
--
-- It DOES return password_hash and salt — deliberately, and only to a caller
-- who has just proved they know the password. That is not a leak: learning the
-- hash of a password you already typed tells you nothing new. It is also
-- REQUIRED, because the app caches those two values on the device so a plant
-- floor with no signal can still log in (see AuthService.signIn step 1). Drop
-- them from this result and you have silently removed offline login.
--
-- The status filter mirrors AuthService._isBlocked: a disabled account must not
-- authenticate even with the right password. Note the app currently
-- distinguishes "wrong password" from "account disabled" in its error message;
-- this function collapses both to "no rows", so the client should call
-- account_status() below to tell the two apart if that message matters.
create or replace function verify_login(p_username text, p_password text)
returns table (
  username      text,
  name          text,
  designation   text,
  plant         text,
  department    text,
  pno           text,
  mobile        text,
  email         text,
  is_admin      boolean,
  status        text,
  password_hash text,
  salt          text
)
language plpgsql
security definer
set search_path = public
as $fn$
begin
  return query
    select u.username, u.name, u.designation, u.plant, u.department,
           u.pno, u.mobile, u.email, u.is_admin, u.status,
           u.password_hash, u.salt
    from   app_users u
    where  u.username = lower(trim(p_username))
      -- Salted format: sha256(salt || plaintext). Legacy rows with a hash but
      -- no salt are handled by the second branch so nobody is locked out
      -- mid-migration; the app rewrites them to the salted format on the next
      -- successful login (AuthService upgrades the server row itself).
      and  (
             (coalesce(u.salt, '') <> ''
               and u.password_hash = encode(digest(u.salt || p_password, 'sha256'), 'hex'))
          or (coalesce(u.salt, '') = ''
               and u.password_hash = encode(digest(p_password, 'sha256'), 'hex'))
           )
      and  coalesce(u.status, 'active') not in ('disabled', 'blocked', 'inactive');
end $fn$;

grant execute on function verify_login(text, text) to anon;

-- Lets the client keep its three distinct error messages ("no such user",
-- "incorrect password", "account disabled") without reading credentials.
-- Returns 'missing' rather than raising, because telling an attacker which
-- usernames exist is a much smaller problem than the hash dump this replaces —
-- but if you would rather not confirm existence at all, drop this function and
-- accept a single generic failure message in the app.
create or replace function account_status(p_username text)
returns text
language sql
security definer
set search_path = public
as $fn$
  select coalesce(
    (select coalesce(u.status, 'active') from app_users u
      where u.username = lower(trim(p_username))),
    'missing');
$fn$;

grant execute on function account_status(text) to anon;


-- ── SECTION 2 : credential-free roster (ADDITIVE — safe to run now) ────────
--
-- The admin panel lists users with the anon key. Once section 3 closes reads,
-- that list goes empty, so this replaces it — same rows, no password_hash and
-- no salt. Note it is NOT restricted to admins: the anon key cannot prove who
-- is calling, so this exposes the roster (names, plants, PNOs, mobiles) to
-- anyone holding that key. That is strictly better than today, where the same
-- caller also gets the hashes, but it is not access control. Real per-user
-- authorisation needs Supabase Auth or a server-side session, which is a
-- larger piece of work than this file.
create or replace function list_app_users_safe()
returns table (
  username    text,
  name        text,
  designation text,
  plant       text,
  department  text,
  pno         text,
  mobile      text,
  email       text,
  is_admin    boolean,
  status      text
)
language sql
security definer
set search_path = public
as $fn$
  select u.username, u.name, u.designation, u.plant, u.department,
         u.pno, u.mobile, u.email, u.is_admin, u.status
  from   app_users u
  order  by coalesce(u.name, u.username);
$fn$;

grant execute on function list_app_users_safe() to anon;


-- ── SECTION 3 : CLOSE THE READ  (⚠ BREAKS LOGIN UNTIL THE CLIENT SHIPS) ────
--
-- Everything above is inert until this runs. Run it only when a build that
-- calls verify_login() is deployed to every platform — web AND the APK, since
-- an old APK in someone's hand keeps using the direct read.
--
-- Reversing it is one statement (the commented rollback below), so this is a
-- safe thing to try during a quiet hour rather than a one-way door.
--
--   drop policy if exists "app_users read" on app_users;
--   create policy "app_users read" on app_users
--     for select using (false);
--
-- ROLLBACK:
--   drop policy if exists "app_users read" on app_users;
--   create policy "app_users read" on app_users for select using (true);


-- ── STILL OPEN after all three sections — do not mistake this for done ─────
--
-- 1. The UPDATE policy is still `using (true)`. Anyone with the anon key can
--    overwrite any row, including `password_hash` — that is account takeover,
--    and it is arguably worse than the read this file closes. It cannot be
--    fixed with a policy alone, because the app has no server-verifiable
--    identity: the admin panel legitimately edits other people's rows, and
--    self-service password reset legitimately edits your own. The fix is to
--    route both through `security definer` functions that require proof (the
--    old password, or a reset token) and then set the policy to `using
--    (false)`. Same for INSERT, which currently lets anyone create an account
--    with `is_admin = true`.
-- 2. `verify_login` has no rate limiting. Postgres cannot easily do that; a
--    per-username attempt counter table checked inside the function is the
--    usual answer.
-- 3. Passwords are salted SHA-256 because the device must be able to verify
--    offline. That is a real constraint, not an oversight, but it does mean a
--    stolen hash is cheap to attack — so the 6-character minimum in
--    validators.dart is a floor, not a defence.
--
-- ── DART CHANGES REQUIRED BEFORE SECTION 3 ─────────────────────────────────
--
-- In lib/services/supabase_service.dart:
--   • add verifyLogin(username, plaintext) → _db.rpc('verify_login',
--     params: {'p_username': u, 'p_password': p}), returning the first row or
--     null. Keep returning password_hash/salt to the caller so the local cache
--     still works.
--   • add accountStatus(username) → _db.rpc('account_status', ...).
--   • point listUsers() at _db.rpc('list_app_users_safe') instead of
--     .from('app_users').select().
--   • getUserByUsername() is the function that must STOP being used on the
--     login path. Audit its other callers first — password reset and the admin
--     panel both use it, and both will start getting null once reads close.
--
-- In lib/services/auth_service.dart (signIn, ~line 339):
--   • replace "fetch row, compare hash locally" with "call verifyLogin, and on
--     null call accountStatus to choose the error message".
--   • the local-cache-first branch above it stays exactly as it is — that is
--     the offline path and it must keep working with no network at all.
--   • _matchLoginPassword's legacy-format upgrade still applies: verify_login
--     accepts an unsalted legacy hash, so the client should keep rewriting
--     those rows to the salted format after a successful login.
-- ═══════════════════════════════════════════════════════════════════════════
