-- ═══════════════════════════════════════════════════════════════════════════
--  SAIL Safety Lens — Supabase setup for USER ACCOUNTS (app_users)
--  Run this ONCE in the Supabase dashboard: SQL Editor → New query → paste →
--  Run.  Safe to re-run (idempotent: IF NOT EXISTS / drop-then-create).
--
--  WHAT THIS IS FOR
--  One row per person who can log in: employees, contractors and admins. This
--  is the app's OWN credential store — it deliberately does not use Supabase
--  Auth, because the app must keep working offline on a plant floor with no
--  signal, and Supabase Auth cannot issue or verify a session without network.
--  So the app stores a salted password hash here, caches it on the device, and
--  verifies locally.
--
--  WHY THIS FILE EXISTS
--  Until now `app_users` was only ever described in a fenced code block inside
--  SUPABASE_MIGRATION_GUIDE.md. Two things went wrong as a result:
--    1. Projects were set up by hand, so some had no `salt` column and some had
--       no UNIQUE constraint on `username`. The app upserts with
--       `onConflict: 'username'` (supabase_service.dart → upsertUser), and
--       PostgREST rejects that outright unless a unique index backs the column.
--       The symptom was a registration that appeared to succeed on the device
--       but never reached the server, so the same login failed on every other
--       device with "Invalid credentials".
--    2. lib/services/auth_service.dart tells the user "Ask your admin to run
--       the app_users migration" — and there was no migration to run.
--
--  THE CREDENTIAL FORMAT  (do not change without changing auth_service.dart)
--    salt          = 16 random bytes, lower-case hex (32 chars)
--    password_hash = sha256(salt + plaintext), lower-case hex
--  The two are always written together, by exactly one function
--  (AuthService._persistCredential). A row with a hash but no salt is a legacy
--  record; the app upgrades it in place the next time that person logs in
--  successfully. Nothing here should ever contain a plaintext password — there
--  is intentionally no `password` column, and the app's column map drops that
--  key if it is ever passed.
--
--  ⚠ SECURITY POSTURE — READ THIS
--  Every device ships the anon (publishable) key, and login has to read the
--  hash for the username being verified. With the permissive policy in STEP 3,
--  anyone holding that key can read EVERY row, including password_hash and
--  salt. Salted SHA-256 is fast, so a short or common password can be brute
--  forced offline from a stolen dump. Two consequences:
--    • The 6-character minimum in validators.dart is a floor, not a defence.
--      Encourage longer passwords.
--    • If this app ever holds anything more sensitive than safety
--      observations, apply the hardening in STEP 5 first.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── STEP 1 : table ─────────────────────────────────────────────────────────
create table if not exists app_users (
  username      text primary key,        -- stored LOWER-CASE by the app
  name          text,
  designation   text,
  plant         text,
  department    text,
  pno           text,                    -- personnel number; used as reset proof
  mobile        text,                    -- used as reset proof
  email         text,                    -- used as reset proof
  is_admin      boolean default false,
  status        text default 'active',   -- 'active' | 'disabled' | 'blocked' | 'inactive'
  password_hash text,                    -- sha256(salt + password), hex
  salt          text,                    -- 16 bytes, hex; null on legacy rows
  created_at    timestamptz default now()
);

-- ── STEP 2 : repair tables created before this file existed ────────────────
-- `create table if not exists` above is a no-op on an existing table, so any
-- column added later has to be back-filled explicitly. `salt` is the one that
-- bit us: without it the app could write a hash it could never verify.
alter table app_users add column if not exists name          text;
alter table app_users add column if not exists designation   text;
alter table app_users add column if not exists plant         text;
alter table app_users add column if not exists department    text;
alter table app_users add column if not exists pno           text;
alter table app_users add column if not exists mobile        text;
alter table app_users add column if not exists email         text;
alter table app_users add column if not exists is_admin      boolean default false;
alter table app_users add column if not exists status        text default 'active';
alter table app_users add column if not exists password_hash text;
alter table app_users add column if not exists salt          text;
alter table app_users add column if not exists created_at    timestamptz default now();

-- If a plaintext `password` column was ever created by hand, get rid of it.
-- The app never writes to it and its mere presence invites someone to.
alter table app_users drop column if exists password;

-- Guarantee the constraint that `upsert(..., onConflict: 'username')` needs.
-- On a table created by STEP 1 the primary key already provides it; this only
-- matters for a table that was built with a surrogate id instead.
do $$
begin
  if not exists (
    select 1
    from   pg_index i
    join   pg_class c on c.oid = i.indrelid
    join   pg_attribute a on a.attrelid = c.oid and a.attnum = any (i.indkey)
    where  c.relname = 'app_users'
      and  a.attname = 'username'
      and  i.indisunique
      and  i.indnatts = 1
  ) then
    create unique index app_users_username_key on app_users (username);
  end if;
end $$;

-- Usernames are compared case-insensitively by the app (AuthService._findLocal
-- lower-cases both sides) but stored as given. Normalise anything already in
-- the table so the two can never disagree, then rely on the app to keep it
-- that way. Runs before the index check would matter because a collision here
-- is a real duplicate account that a human has to resolve.
update app_users
   set username = lower(username)
 where username <> lower(username)
   and not exists (
     select 1 from app_users b where b.username = lower(app_users.username)
   );

create index if not exists app_users_plant_idx  on app_users (plant);
create index if not exists app_users_pno_idx     on app_users (pno);
create index if not exists app_users_status_idx  on app_users (status);

-- ── STEP 3 : Row Level Security ────────────────────────────────────────────
-- The app authenticates with the anon key and gates admin features in its own
-- UI, not at the database level. Login must be able to SELECT the row for the
-- username being verified, and registration must be able to INSERT, so both
-- are open. See STEP 5 for how to close this properly.
alter table app_users enable row level security;

drop policy if exists "app_users read"   on app_users;
drop policy if exists "app_users insert" on app_users;
drop policy if exists "app_users update" on app_users;
drop policy if exists "app_users delete" on app_users;

create policy "app_users read"   on app_users for select using (true);
create policy "app_users insert" on app_users for insert with check (true);
create policy "app_users update" on app_users for update using (true);

-- Deliberately NO delete policy. The app deactivates people by setting
-- status = 'disabled' (AuthService._isBlocked honours it) and never deletes,
-- because incidents reference the reporter by name and PNO. Leaving delete
-- unpolicied means a leaked anon key cannot wipe the user table.

-- ── STEP 4 : verify ────────────────────────────────────────────────────────
select column_name, data_type, is_nullable
from   information_schema.columns
where  table_schema = 'public' and table_name = 'app_users'
order  by ordinal_position;

-- Accounts that still need a credential upgrade (hash present, salt missing).
-- These log in once against the legacy format and are rewritten immediately;
-- the count should trend to zero on its own.
--   select count(*) from app_users
--   where coalesce(password_hash,'') <> '' and coalesce(salt,'') = '';

-- Accounts with no way to self-serve a password reset — no pno, no mobile, no
-- email means AuthService.resetPasswordWithProof has nothing to check against
-- and will refuse. An admin has to reset these from the admin panel.
--   select username, name, plant from app_users
--   where coalesce(pno,'') = '' and coalesce(mobile,'') = ''
--     and coalesce(email,'') = '';

-- ── STEP 5 : OPTIONAL hardening (requires a client change — read first) ────
-- The block below stops the anon key from reading hashes at all, by moving
-- verification into the database. DO NOT run it as-is: the current app reads
-- password_hash and salt directly in supabase_service.getUserByUsername, so
-- revoking select would break login on every device until the client is
-- updated to call verify_login() instead.
--
--   create or replace function verify_login(p_username text, p_password text)
--   returns table (username text, name text, designation text, plant text,
--                  department text, pno text, mobile text, email text,
--                  is_admin boolean, status text)
--   language plpgsql security definer set search_path = public as $fn$
--   begin
--     return query
--       select u.username, u.name, u.designation, u.plant, u.department,
--              u.pno, u.mobile, u.email, u.is_admin, u.status
--       from   app_users u
--       where  u.username = lower(p_username)
--         and  u.password_hash = encode(
--                digest(u.salt || p_password, 'sha256'), 'hex')
--         and  coalesce(u.status, 'active') not in
--                ('disabled', 'blocked', 'inactive');
--   end $fn$;
--
--   -- needs: create extension if not exists pgcrypto;
--   drop policy if exists "app_users read" on app_users;
--   create policy "app_users read" on app_users for select
--     using (false);          -- reads only through verify_login()
--   grant execute on function verify_login(text, text) to anon;
--
-- Note this also removes the admin panel's ability to list users with the anon
-- key, so it needs a second definer function returning the roster without
-- credential columns. Worth doing before this app is used for anything beyond
-- safety observations.
