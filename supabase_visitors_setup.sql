-- ============================================================================
-- Safety Lens — unique visitor counter
-- ============================================================================
-- RUN THIS ONCE in the Supabase SQL Editor (Dashboard -> SQL Editor -> New query
-- -> paste -> Run). Until it is run, both admin panels show "—" for visitors;
-- they will NOT show 0, so you can tell "not set up" apart from "nobody yet".
--
-- Safe to re-run: every statement is idempotent.
--
-- WHY A NEW TABLE?
-- `user_sessions` / `session_logs` already exist in this project but nothing in
-- `lib/` ever writes to them — they are dead schema. Building on them would have
-- meant building on something that is never populated.
--
-- SECURITY MODEL — this matters, read before changing:
-- The anon key is PUBLIC (it ships in the web bundle and in admin/index.html).
-- So the table has RLS enabled with NO anon policies at all: anon cannot select,
-- insert or update rows directly, and therefore cannot enumerate who visited.
-- All access goes through the two SECURITY DEFINER functions below, which run as
-- the owner and expose exactly two things: "record my own visit" and "give me
-- AGGREGATE counts". Individual visitor rows are never readable by the client.
-- ============================================================================

-- ── 1. Table ────────────────────────────────────────────────────────────────
create table if not exists public.app_visitors (
  -- Client-generated UUID v4, persisted in SharedPreferences. This is the unit
  -- of "unique visitor": one per browser profile / per app install.
  visitor_id   text primary key,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  -- Null while the visitor is anonymous. Once known, it is never cleared back to
  -- null (see the coalesce in record_visit) so logging out cannot make the
  -- signed-in-staff count drift downward.
  employee_id  text,
  platform     text,
  app_version  text,
  visit_count  integer not null default 1
);

-- Columns added defensively in case an older version of this table exists.
alter table public.app_visitors add column if not exists employee_id  text;
alter table public.app_visitors add column if not exists platform     text;
alter table public.app_visitors add column if not exists app_version  text;
alter table public.app_visitors add column if not exists visit_count  integer not null default 1;

-- Supports the today / 7d / 30d windows in get_visitor_stats().
create index if not exists idx_app_visitors_last_seen
  on public.app_visitors (last_seen_at desc);

-- Partial: only rows that actually have an employee are ever counted, and the
-- anonymous rows (expected to be the majority) stay out of the index.
create index if not exists idx_app_visitors_employee
  on public.app_visitors (employee_id)
  where employee_id is not null;

-- ── 2. Lock the table down ──────────────────────────────────────────────────
-- Enabled with NO policies created on purpose. Direct REST access to this table
-- returns zero rows for anon/authenticated. Do not add a policy here unless you
-- genuinely want visitor rows to be publicly enumerable.
alter table public.app_visitors enable row level security;

-- ── 3. Record a visit ───────────────────────────────────────────────────────
create or replace function public.record_visit(
  p_visitor_id  text,
  p_employee_id text default null,
  p_platform    text default null,
  p_app_version text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_visitor_id is null or length(trim(p_visitor_id)) = 0 then
    return;  -- nothing usable; fail quietly rather than error the client
  end if;

  insert into public.app_visitors as v (
    visitor_id, employee_id, platform, app_version,
    first_seen_at, last_seen_at, visit_count
  )
  values (
    p_visitor_id, p_employee_id, p_platform, p_app_version,
    now(), now(), 1
  )
  on conflict (visitor_id) do update
    set last_seen_at = now(),
        visit_count  = v.visit_count + 1,
        -- coalesce(new, old): a later ANONYMOUS visit from a device that has
        -- previously signed in must not wipe the employee_id, or unique_employees
        -- would shrink over time. New non-null values still win, so a shared
        -- device correctly re-attributes to whoever signed in most recently.
        employee_id  = coalesce(excluded.employee_id, v.employee_id),
        platform     = coalesce(excluded.platform,    v.platform),
        app_version  = coalesce(excluded.app_version, v.app_version);
end;
$$;

-- ── 4. Read aggregate stats ─────────────────────────────────────────────────
create or replace function public.get_visitor_stats()
returns json
language sql
security definer
set search_path = public
as $$
  -- Returns a single JSON OBJECT (not a table). The Dart and JS clients both
  -- expect a Map; changing this to `returns table(...)` would make PostgREST
  -- emit an array and silently break both counters.
  select json_build_object(
    'unique_visitors',  (select count(*) from public.app_visitors),
    'unique_employees', (select count(distinct employee_id)
                           from public.app_visitors
                          where employee_id is not null),
    'visitors_today',   (select count(*) from public.app_visitors
                          where last_seen_at >= date_trunc('day', now())),
    'visitors_7d',      (select count(*) from public.app_visitors
                          where last_seen_at >= now() - interval '7 days'),
    'visitors_30d',     (select count(*) from public.app_visitors
                          where last_seen_at >= now() - interval '30 days'),
    'total_visits',     (select coalesce(sum(visit_count), 0)
                           from public.app_visitors),
    'generated_at',     now()
  );
$$;

-- ── 5. Grants ───────────────────────────────────────────────────────────────
-- Revoke the default blanket EXECUTE that Postgres grants to PUBLIC, then grant
-- deliberately. These are the ONLY two doors into the table.
revoke all on function public.record_visit(text, text, text, text) from public;
revoke all on function public.get_visitor_stats() from public;

grant execute on function public.record_visit(text, text, text, text) to anon, authenticated;
grant execute on function public.get_visitor_stats() to anon, authenticated;

-- ── 6. Verify ───────────────────────────────────────────────────────────────
-- Should return a JSON object with all-zero counts on a fresh install:
--   select public.get_visitor_stats();
-- Should show rls_enabled = true:
--   select relname, relrowsecurity as rls_enabled
--     from pg_class where relname = 'app_visitors';
-- Should return 0 rows even with the anon key (proving rows aren't enumerable):
--   (from the browser)  GET /rest/v1/app_visitors?select=*
