-- ═══════════════════════════════════════════════════════════════════════════
--  Safety Lens — MAMR (My Area My Responsibility) migration
--  Run this ONCE in the Supabase SQL editor (Dashboard → SQL Editor → New query)
--  BEFORE installing the build that contains the MAMR tab.
-- ═══════════════════════════════════════════════════════════════════════════
--
--  What it adds: six columns on `incidents` that tie an observation to an area
--  of the plant's area-responsibility register.
--
--  If you install the app first: nothing breaks. upsertIncident drops an
--  unknown column and retries, so observations still sync — but WITHOUT their
--  area, category and responsible person, so other devices (and the Reports →
--  MAMR statistics) would not see them as MAMR. Run this first.
--
--  The registers themselves need no new table. They live in the existing
--  `master_data` table under keys `mamr_areas_<PLANT CODE>` (e.g.
--  mamr_areas_ASP), and the SED list under `mamr_sed`. The existing realtime
--  subscription on master_data carries them to every device.
--
--  Safe to re-run: every statement uses IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.incidents add column if not exists mamr_area_id     text;
alter table public.incidents add column if not exists mamr_dept        text;
alter table public.incidents add column if not exists mamr_area        text;
alter table public.incidents add column if not exists mamr_category    text;
-- Responsible person(s) AT THE TIME OF FILING: [{name, designation, mobile,
-- username}]. A snapshot on purpose — reassigning an area later must not
-- rewrite who owned an old observation.
alter table public.incidents add column if not exists mamr_responsible jsonb;
-- The reporter's own department. For MAMR observations `dept` holds the
-- AREA's department (where the hazard is), so the reporter's is kept here.
alter table public.incidents add column if not exists reporter_dept    text;

-- Reports → MAMR filters by plant + area and orders by date.
create index if not exists idx_incidents_mamr_area
  on public.incidents (plant, mamr_area_id);
create index if not exists idx_incidents_type
  on public.incidents (type);

-- Realtime: master_data must be in the realtime publication for SED edits to
-- reach other devices live (it already is if plant/department edits sync
-- live today). Uncomment only if they do not:
-- alter publication supabase_realtime add table public.master_data;
