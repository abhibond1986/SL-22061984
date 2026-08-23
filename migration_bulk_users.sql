-- ═══════════════════════════════════════════════════════════════════════════
--  SAIL Safety Lens — BULK EMPLOYEE IMPORT support for app_users
--  Run ONCE in the Supabase dashboard: SQL Editor → New query → paste → Run.
--  Safe to re-run (every statement is IF NOT EXISTS / idempotent).
--
--  PREREQUISITE: supabase_app_users_setup.sql must have been run first. This
--  file only ADDS to that table; it never redefines the credential columns.
--
--  WHAT THIS IS FOR
--  The quarterly SAIL employee list (emp_list_<Month> <Year>.xls, ~10,000 rows,
--  columns NAME / GRADE / DESIG / DEPT / UNIT / EMAIL / MOBILE_NO / RETIRE_DT /
--  DOB / SAIL_PNO) is imported into app_users so that every employee can sign in
--  with their SAIL P.no. app_users already held name, designation, plant,
--  department, pno, mobile and email; this adds the remaining profile fields and
--  the bookkeeping the import needs.
--
--  SCALE NOTE — this is the thing to keep in mind when changing anything here.
--  The January 2026 file has 10,086 rows. That is ~2.3 MB of JSON, which is why
--  the app does NOT mirror the roster into device storage (browser origins are
--  typically capped at 5 MB and the app already caches incidents and images
--  there). User search runs against THIS table instead, so the indexes at the
--  bottom are load-bearing, not decoration.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── STEP 1 : profile columns from the employee list ────────────────────────
-- All nullable and all free-text-or-date: this is reference data copied from an
-- HR export, not something the app validates or depends on for access control.
-- The one exception is retire_dt, which the import uses to disable leavers.
alter table app_users add column if not exists grade      text;   -- E0..E9, DIR, CHA
alter table app_users add column if not exists unit       text;   -- BSP, RSP, ASP, CMO…
alter table app_users add column if not exists dob        date;
alter table app_users add column if not exists retire_dt  date;

-- ── STEP 2 : first-login password change ───────────────────────────────────
-- Imported accounts start with the P.no as the password. A P.no is printed on
-- an ID card and appears in the spreadsheet itself, so it is a bootstrap
-- credential, NOT a secret: until the person replaces it, anyone holding the
-- file could sign in as them and file or close safety reports in their name.
-- The app refuses to open the portal while this flag is true.
--
-- Default false so that the accounts that already exist — including the admin —
-- are unaffected by this migration. Only the importer sets it true.
alter table app_users add column if not exists must_change_password boolean default false;

-- ── STEP 3 : import bookkeeping ────────────────────────────────────────────
-- Which upload a row came from, so a bad quarter can be identified after the
-- fact. import_batch is the filename plus a timestamp, chosen by the importer.
alter table app_users add column if not exists import_source text;   -- 'bulk_import' | 'manual'
alter table app_users add column if not exists import_batch  text;
alter table app_users add column if not exists imported_at   timestamptz;
alter table app_users add column if not exists updated_at    timestamptz;

-- ── STEP 3b : who an investigation is assigned to, in words ────────────────
-- incidents.assigned_to holds a username, which after the import is a SAIL P.no
-- ("a000168"). That is unreadable on a supervisor's screen, and joining 10,000
-- users to a list of incidents to resolve it is not a query worth running on
-- every dashboard load — so the name is denormalised at assignment time.
--
-- The app tolerates this column being absent (upsertIncident drops unknown
-- columns and retries), so a delayed migration costs the name, not the record.
alter table incidents add column if not exists assigned_to_name text;

-- ── STEP 4 : indexes for search at 10k rows ────────────────────────────────
-- The assign-investigator picker searches on name AND P.no from the incident
-- screen, so both need to be indexed. pno already has an index from the setup
-- file; these add case-insensitive name search.
create index if not exists app_users_name_lower_idx on app_users (lower(name));
create index if not exists app_users_unit_idx       on app_users (unit);
create index if not exists app_users_retire_dt_idx  on app_users (retire_dt);

-- Substring search ("sub" → SUBBARAJ) needs trigrams; a plain b-tree only helps
-- prefix matches. Wrapped in a DO block because pg_trgm is available on Supabase
-- but creating an extension needs privileges that a restricted role may lack —
-- and if it fails the picker still works, just with prefix matching. Never let
-- an optional index take the whole migration down.
do $$
begin
  create extension if not exists pg_trgm;
  create index if not exists app_users_name_trgm_idx
    on app_users using gin (lower(name) gin_trgm_ops);
  create index if not exists app_users_pno_trgm_idx
    on app_users using gin (lower(pno) gin_trgm_ops);
exception when others then
  raise notice 'pg_trgm unavailable (%) — falling back to prefix search on name/pno', sqlerrm;
end $$;

-- ── STEP 5 : verify ────────────────────────────────────────────────────────
select column_name, data_type, is_nullable
from   information_schema.columns
where  table_schema = 'public' and table_name = 'app_users'
  and  column_name in ('grade','unit','dob','retire_dt',
                       'must_change_password','import_source','import_batch',
                       'imported_at','updated_at')
order  by column_name;
-- EXPECT 9 rows. If any are missing, STEP 1–3 did not run — stop and re-run.

select column_name from information_schema.columns
where  table_schema = 'public' and table_name = 'incidents'
  and  column_name = 'assigned_to_name';
-- EXPECT 1 row (STEP 3b).

select indexname from pg_indexes
where  schemaname = 'public' and tablename = 'app_users'
order  by indexname;
-- EXPECT app_users_name_lower_idx, app_users_pno_idx, app_users_plant_idx,
-- app_users_status_idx, app_users_unit_idx, app_users_retire_dt_idx and the
-- username unique index. The two _trgm_ idx entries appear only if pg_trgm
-- could be created — their absence is not an error.

-- ── AFTER THE FIRST IMPORT — useful checks ─────────────────────────────────
-- How many accounts still hold the P.no as their password:
--   select count(*) from app_users where must_change_password;
--
-- Retired people who can still log in (the importer should have disabled these;
-- if this returns rows, the retirement cut-off did not apply):
--   select username, name, unit, retire_dt from app_users
--   where  retire_dt < current_date
--     and  coalesce(status,'active') = 'active'
--   order  by retire_dt;
--
-- Headcount per unit, to compare against the spreadsheet before trusting it:
--   select coalesce(unit,'(none)') as unit, count(*)
--   from   app_users group by 1 order by 2 desc;
