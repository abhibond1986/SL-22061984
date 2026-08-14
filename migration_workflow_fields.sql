-- ═══════════════════════════════════════════════════════════════════════════
--  Safety Lens — workflow / closure fields migration
--  Run this ONCE in the Supabase SQL editor (Dashboard → SQL Editor → New query).
-- ═══════════════════════════════════════════════════════════════════════════
--
--  WHY THIS IS REQUIRED, NOT OPTIONAL:
--  The app now syncs the incident workflow fields (corrective action author,
--  closure remarks, timestamps, assignment, target date). PostgREST rejects an
--  ENTIRE row if it mentions one column that does not exist — so if the app
--  sends `closed_by` and the table lacks it, EVERY incident upsert fails, not
--  just that field. Run this before (or immediately after) deploying the build
--  that includes the workflow sync.
--
--  Safe to re-run: every statement uses IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.incidents add column if not exists investigation_started_at text;
alter table public.incidents add column if not exists action_taken_at          text;
alter table public.incidents add column if not exists closed_by               text;
alter table public.incidents add column if not exists closing_remarks         text;
alter table public.incidents add column if not exists closed_at               text;
alter table public.incidents add column if not exists assigned_to             text;
alter table public.incidents add column if not exists assigned_at             text;

-- Target date for closure. New field — nothing populated it before.
alter table public.incidents add column if not exists target_date             text;

-- Last local modification time. Used to decide whether an incoming realtime
-- row is newer than an unsynced local edit, so live sync stops clobbering
-- work typed on the device.
--
-- NOTE: if your table was created from SUPABASE_MIGRATION_GUIDE.md it ALREADY
-- has `updated_at timestamptz default now()`, and `add column if not exists`
-- is then a silent no-op — the column stays timestamptz. That is fine and no
-- action is needed: the app now writes this value in UTC with a trailing 'Z'
-- (LocalDB.saveIncident), so it survives a timestamptz round-trip unchanged in
-- absolute terms and the comparison in mergeServerIncident stays correct.
-- The type is therefore not load-bearing; do NOT alter an existing column.
alter table public.incidents add column if not exists updated_at              text;

-- The other timestamps above are plain text because the app only ever displays
-- or string-sorts them; text avoids Postgres reformatting values that the app
-- wrote, and avoids a cast error on any legacy non-ISO value already stored.

-- The plant dashboard filters by plant + department and orders by date.
create index if not exists idx_incidents_plant_dept
  on public.incidents (plant, dept);
create index if not exists idx_incidents_status
  on public.incidents (status);

-- Force PostgREST to re-read the schema. Supabase normally does this itself via
-- an event trigger, but when it lags, the API keeps rejecting the new columns
-- with PGRST204 ("could not find the column in the schema cache") even though
-- the DDL above succeeded — which looks exactly like the migration not working.
notify pgrst, 'reload schema';

-- ── Verify ──
-- Should list all nine columns added above.
select column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name  = 'incidents'
  and column_name in (
    'investigation_started_at','action_taken_at','closed_by','closing_remarks',
    'closed_at','assigned_to','assigned_at','target_date','updated_at')
order by column_name;
