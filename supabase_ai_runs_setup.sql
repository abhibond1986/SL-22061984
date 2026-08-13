-- ═══════════════════════════════════════════════════════════════════════════
--  SAIL Safety Lens — Supabase setup for AI RUN TELEMETRY
--  Run this ONCE in the Supabase dashboard: SQL Editor → New query → paste →
--  Run.  Safe to re-run (idempotent: uses IF NOT EXISTS / drop-then-create).
--
--  WHAT THIS IS FOR
--  One row per AI analysis attempt — hazard scan, near-miss image analysis, or
--  near-miss text refinement. It answers, for the admin only: how many runs
--  happened today, how many actually succeeded, how long they took, and which
--  provider/model served them.
--
--  WHY IT IS NEEDED
--  Before this table there was NO way to answer those questions. The vision
--  service never throws on failure — when every provider fails it quietly
--  returns an offline checklist that looks like a valid result (riskScore 0,
--  _isOnline false). So failures were invisible: ErrorLogService.getSuccessRate()
--  was a placeholder that computed (100 - errorCount)/100 with no success
--  counter at all, and its own source carried a "TODO: Track successful
--  operations". The single Stopwatch in the app (gemini_vision.dart) measured
--  each run and then only printed the number to the debug console.
--
--  WHAT COUNTS AS SUCCESS  (decided with the admin, do not change silently)
--    SUCCESS — a real provider returned hazards for the image.
--    FAILED  — includes the offline / knowledge-bank fallback. The fallback
--              returns text, but the AI never saw the image, so counting it as
--              success would make a total provider outage look like a 100% pass
--              rate. fail_reason distinguishes an outage from a bad model.
--    CACHED  — an identical image was already analysed. Counted separately and
--              EXCLUDED from timing, because cache hits return in a few
--              milliseconds and would otherwise flatter the average badly.
--
--  PRIVACY
--  No image bytes and no free text are stored here — only an image hash,
--  counts, timings and the reporter's name/PNO, which the app already records
--  on every incident.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── STEP 1 : ai_runs table ─────────────────────────────────────────────────
create table if not exists ai_runs (
  id             text primary key,       -- client-generated run id
  run_type       text,                   -- 'HAZARD_SCAN' | 'NEAR_MISS_IMAGE' | 'NEAR_MISS_TEXT' | 'FIELD_REFINE'
  outcome        text,                   -- 'SUCCESS' | 'FAILED' | 'CACHED'
  fail_reason    text,                   -- short code, e.g. 'no_internet', 'providers_exhausted', 'concurrent', 'exception', 'empty_result'
  provider       text,                   -- '_source' from the result, e.g. openrouter_client / gemini_direct / knowledge_bank_fallback
  model          text,                   -- specific model id when known
  duration_ms    integer,                -- wall-clock for the whole attempt
  hazard_count   integer,                -- hazards returned (0 on failure)
  confidence     integer,                -- AI confidence 0-100 (0 on failure)
  image_hash     text,                   -- ties a run to the same photo; joins to ai_corrections.image_hash
  plant          text,
  dept           text,
  user_name      text,
  user_pno       text,
  app_version    text,
  platform       text,                   -- 'Android' | 'iOS' | 'Web'
  created_at     timestamptz default now()
);

-- Indexes for the admin dashboard: it filters by day, then groups by outcome,
-- run type and provider.
create index if not exists ai_runs_created_idx   on ai_runs (created_at desc);
create index if not exists ai_runs_outcome_idx   on ai_runs (outcome);
create index if not exists ai_runs_type_idx      on ai_runs (run_type);
create index if not exists ai_runs_provider_idx  on ai_runs (provider);
create index if not exists ai_runs_plant_idx     on ai_runs (plant);

-- ── STEP 2 : Row Level Security ────────────────────────────────────────────
-- Same posture as ai_corrections: the app uses the anon (publishable) key and
-- access is gated by the app's own admin login, not Supabase Auth.
--
-- NOTE ON THE READ POLICY: every device must be able to INSERT its own runs,
-- and `using (true)` on select means the anon key can read the whole table.
-- That is consistent with every other table in this project, but be aware the
-- dashboard itself is admin-only in the UI, not at the database level.
alter table ai_runs enable row level security;

drop policy if exists "ai_runs read"   on ai_runs;
drop policy if exists "ai_runs insert" on ai_runs;
drop policy if exists "ai_runs update" on ai_runs;
drop policy if exists "ai_runs delete" on ai_runs;

create policy "ai_runs read"
  on ai_runs for select
  using (true);

create policy "ai_runs insert"
  on ai_runs for insert
  with check (true);

create policy "ai_runs update"
  on ai_runs for update
  using (true);

create policy "ai_runs delete"
  on ai_runs for delete
  using (true);

-- ── STEP 3 : Realtime (optional) ───────────────────────────────────────────
-- So the admin dashboard updates live while users run scans on their own
-- devices (add-only; won't disturb tables already published).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'ai_runs'
  ) then
    alter publication supabase_realtime add table ai_runs;
  end if;
end $$;

alter table ai_runs replica identity full;

-- ── Verify ─────────────────────────────────────────────────────────────────
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'ai_runs'
order by ordinal_position;

-- ── Handy queries once data arrives ────────────────────────────────────────
-- Today's performance, mirroring what the admin panel computes:
--   select outcome, count(*), round(avg(duration_ms)) as avg_ms
--   from ai_runs
--   where created_at >= current_date
--   group by outcome;
--
-- Why runs are failing today:
--   select fail_reason, count(*) from ai_runs
--   where outcome = 'FAILED' and created_at >= current_date
--   group by fail_reason order by 2 desc;
--
-- Which model is fastest (cache hits excluded, as in the dashboard):
--   select model, count(*), round(avg(duration_ms)) as avg_ms
--   from ai_runs
--   where outcome = 'SUCCESS' and created_at >= current_date - interval '7 days'
--   group by model order by 3;
