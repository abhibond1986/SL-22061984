-- ═══════════════════════════════════════════════════════════════════════════
--  SAIL Safety Lens — Phase 1C, SAFE STEPS  (written 2026-09-27)
--
--  Run in the Supabase dashboard: SQL Editor → New query → paste → Run.
--  Idempotent: safe to re-run. Every section is ADDITIVE — nothing here
--  closes a read or write policy, so no existing device or APK stops working.
--
--  Prerequisite: supabase_app_users_setup.sql has been run (app_users exists).
--
--  WHAT THIS DOES
--    1. Adds a `role` column and migrates is_admin = true → corporate_admin,
--       everyone else → employee. is_admin is KEPT and kept in sync both ways
--       (dual-write), so rolling back is just "stop reading role".
--    2. New accounts can never be born privileged: a brand-new row is forced
--       to role 'employee' / is_admin false, whatever the client sent.
--    3. A server-side audit table. Role / admin changes are recorded by a
--       trigger, so they are logged even if the change bypasses the app.
--    4. Server-side password check with a failed-attempt lock
--       (sl_verify_login / sl_account_status). The app calls these first and
--       falls back to the old path only while reads are still open.
--
--  WHAT THIS DELIBERATELY DOES NOT DO (the later, breaking step)
--    Close the open RLS policies on app_users / incidents. That waits until a
--    build calling sl_verify_login is live on web AND the APK and has been
--    checked. See "NEXT STEP" at the bottom.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;


-- ── SECTION 1 : role column + backfill ─────────────────────────────────────
alter table app_users add column if not exists role text;

update app_users
   set role = case when coalesce(is_admin, false) then 'corporate_admin'
                   else 'employee' end
 where role is null;

alter table app_users alter column role set default 'employee';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'app_users_role_check') then
    alter table app_users add constraint app_users_role_check check (role in (
      'employee', 'supervisor', 'safety_officer', 'plant_admin',
      'corporate_admin'));
  end if;
end $$;

create or replace function sl_is_admin_role(r text) returns boolean
language sql immutable as $$
  select coalesce(r, '') in ('plant_admin', 'corporate_admin');
$$;


-- ── SECTION 2 : audit table (server-side, not per-device) ──────────────────
create table if not exists audit_events (
  id      bigserial primary key,
  at      timestamptz not null default now(),
  actor   text,
  action  text not null,
  target  text,
  detail  jsonb,
  source  text not null default 'app'   -- 'app' = client-reported, 'db' = trigger
);
create index if not exists audit_events_at_idx on audit_events (at desc);
create index if not exists audit_events_action_idx on audit_events (action);

-- RLS on with NO policies: the anon key can neither read nor write the table
-- directly. Writes go through sl_log_audit_event below; reads are for the
-- Supabase dashboard (service role) until Phase 1C step 3 adds admin reads.
alter table audit_events enable row level security;

create or replace function sl_log_audit_event(
  p_actor text, p_action text, p_target text default null,
  p_detail jsonb default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_action), '') = '' then return; end if;
  insert into audit_events (actor, action, target, detail, source)
  values (left(p_actor, 120), left(p_action, 60), left(p_target, 200),
          case when p_detail is null or length(p_detail::text) <= 4000
               then p_detail else jsonb_build_object('truncated', true) end,
          'app');
end $$;
grant execute on function sl_log_audit_event(text, text, text, jsonb) to anon;


-- ── SECTION 3 : role guard + dual-write trigger ────────────────────────────
--
-- INSERT of a genuinely new username → always employee / not admin.
--   Note: PostgREST upserts arrive as INSERT … ON CONFLICT, and BEFORE INSERT
--   fires for those too. If the username already exists this is really an
--   update, so it is left alone here and the UPDATE branch handles it —
--   otherwise every profile save of an existing admin would demote them.
-- UPDATE → keep role and is_admin consistent, and audit any change.
create or replace function sl_app_users_role_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not exists (select 1 from app_users u where u.username = new.username) then
      new.role := 'employee';
      new.is_admin := false;
    end if;
    return new;
  end if;

  -- UPDATE
  if new.role is distinct from old.role then
    new.is_admin := sl_is_admin_role(new.role);
  elsif coalesce(new.is_admin, false) is distinct from coalesce(old.is_admin, false) then
    new.role := case
      when coalesce(new.is_admin, false) then 'corporate_admin'
      when sl_is_admin_role(old.role) then 'employee'
      else old.role end;
  end if;

  if new.role is distinct from old.role then
    insert into audit_events (actor, action, target, detail, source)
    values (null, 'role_changed', new.username,
            jsonb_build_object('from', old.role, 'to', new.role), 'db');
  end if;
  return new;
end $$;

drop trigger if exists app_users_role_guard on app_users;
create trigger app_users_role_guard
  before insert or update on app_users
  for each row execute function sl_app_users_role_guard();


-- ── SECTION 4 : server-side login check + attempt lock ─────────────────────
create table if not exists login_attempts (
  id       bigserial primary key,
  username text not null,
  at       timestamptz not null default now(),
  ok       boolean not null
);
create index if not exists login_attempts_user_at_idx
  on login_attempts (username, at desc);
alter table login_attempts enable row level security;   -- no policies: RPC only

-- 10 failures in 15 minutes locks the username for the rest of that window.
create or replace function sl_login_locked(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select count(*) >= 10 from login_attempts
   where username = lower(trim(p_username))
     and not ok
     and at > now() - interval '15 minutes';
$$;

-- Returns the full user row as JSON (same shape the app reads today, so the
-- offline cache keeps working) on a correct password; NULL otherwise.
-- password_hash / salt are returned only to a caller who just proved the
-- password — see supabase_app_users_hardening.sql for why that is required.
create or replace function sl_verify_login(p_username text, p_password text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_user text := lower(trim(p_username));
  v_row  app_users%rowtype;
  v_ok   boolean;
begin
  if v_user = '' or coalesce(p_password, '') = '' then return null; end if;
  if sl_login_locked(v_user) then return null; end if;

  select * into v_row from app_users u
   where u.username = v_user
     and coalesce(u.status, 'active') not in ('disabled', 'blocked', 'inactive')
     and (
           (coalesce(u.salt, '') <> ''
             and u.password_hash = encode(digest(u.salt || p_password, 'sha256'), 'hex'))
        or (coalesce(u.salt, '') = ''
             and u.password_hash = encode(digest(p_password, 'sha256'), 'hex'))
         )
   limit 1;
  -- Captured now: the INSERT and DELETE below both overwrite FOUND.
  v_ok := found;

  insert into login_attempts (username, ok) values (v_user, v_ok);
  -- Keep the table small: drop anything older than a day.
  delete from login_attempts where at < now() - interval '1 day';

  if not v_ok then return null; end if;
  return to_jsonb(v_row);
end $$;
grant execute on function sl_verify_login(text, text) to anon;

-- 'active' | 'disabled' | 'locked' | 'missing'. Lets the app keep distinct
-- messages without reading credentials.
create or replace function sl_account_status(p_username text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v_status text;
begin
  select coalesce(u.status, 'active') into v_status
    from app_users u where u.username = lower(trim(p_username));
  if v_status is null then return 'missing'; end if;
  if v_status in ('disabled', 'blocked', 'inactive') then return 'disabled'; end if;
  if sl_login_locked(p_username) then return 'locked'; end if;
  return 'active';
end $$;
grant execute on function sl_account_status(text) to anon;


-- ── CHECK : run after the sections above ───────────────────────────────────
-- At least one row must come back, or nobody can open the admin panel once
-- the build that removes the built-in admin/admin gate is deployed.
select username, name, role, is_admin
  from app_users where sl_is_admin_role(role) order by username;


-- ── ROLLBACK (only if something above misbehaves) ──────────────────────────
--   drop trigger if exists app_users_role_guard on app_users;
--   -- the role column, audit_events and login_attempts are harmless to keep.


-- ── NEXT STEP (breaking — NOT in this file) ────────────────────────────────
-- Only after the build that calls sl_verify_login is live on web and the APK,
-- and login has been checked on both:
--   1. Close the app_users read policy (hardening file, section 3).
--   2. Move admin edits and password changes to security-definer functions
--      that require proof (old password / admin session), then close the
--      app_users update and insert policies.
--   3. Issue a server-side session token at login and require it on incident
--      writes, then close the incidents policies.
