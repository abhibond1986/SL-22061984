-- ═══════════════════════════════════════════════════════════════════════════
--  SAIL Safety Lens — Supabase setup for the AI CORRECTIONS feedback loop
--  Run this ONCE in the Supabase dashboard: SQL Editor → New query → paste →
--  Run.  Safe to re-run (idempotent: uses IF NOT EXISTS / drop-then-create).
--
--  WHAT THIS IS FOR
--  When a user edits the AI's output (summary, severity, or corrective action)
--  after a hazard scan or near-miss analysis, the app records the change here.
--  An admin then reviews each edit and decides whether the AI was wrong
--  ("AI mistake") or the user simply preferred different wording
--  ("User preference"). Edits marked as AI mistakes feed the fine-tuning
--  dataset so the model keeps improving.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── STEP 1 : ai_corrections table ──────────────────────────────────────────
create table if not exists ai_corrections (
  id                 text primary key,          -- correction id (client-generated)
  incident_id        text,                       -- the incident the edit belongs to
  incident_type      text,                       -- 'AI_SCAN' | 'NEAR_MISS'
  image_hash         text,                       -- links edits to the same photo
  plant              text,
  field_changed      text,                       -- 'summary' | 'severity' | 'overallRisk' | 'correctiveAction' | 'hazardSeverity'
  hazard_name        text,                       -- for per-hazard edits (nullable)
  original_value     text,                       -- what the AI produced
  edited_value       text,                       -- what the user changed it to
  edited_by          text,                       -- user name / PNO
  ai_source          text,                       -- which model produced the original (e.g. gemini, groq)
  verdict            text default 'pending',     -- 'pending' | 'ai_mistake' | 'user_preference'
  reviewed_by        text,                       -- admin who classified it
  reviewed_at        timestamptz,
  added_to_training  boolean default false,      -- true once pushed to fine-tuning dataset
  created_at         timestamptz default now()
);

-- Helpful indexes for the admin review queue.
create index if not exists ai_corrections_verdict_idx     on ai_corrections (verdict);
create index if not exists ai_corrections_created_idx      on ai_corrections (created_at desc);
create index if not exists ai_corrections_incident_idx     on ai_corrections (incident_id);
create index if not exists ai_corrections_field_idx        on ai_corrections (field_changed);

-- ── STEP 2 : Row Level Security ─────────────────────────────────────────────
-- The app uses the anon (publishable) key. Allow it to read / insert / update
-- corrections. (Same posture as the rest of the app's tables — access is
-- gated by the app's own admin login, not Supabase Auth.)
alter table ai_corrections enable row level security;

drop policy if exists "ai_corrections read"   on ai_corrections;
drop policy if exists "ai_corrections insert"  on ai_corrections;
drop policy if exists "ai_corrections update"  on ai_corrections;
drop policy if exists "ai_corrections delete"  on ai_corrections;

create policy "ai_corrections read"
  on ai_corrections for select
  using (true);

create policy "ai_corrections insert"
  on ai_corrections for insert
  with check (true);

create policy "ai_corrections update"
  on ai_corrections for update
  using (true);

create policy "ai_corrections delete"
  on ai_corrections for delete
  using (true);

-- ── STEP 3 : Realtime (optional but recommended) ───────────────────────────
-- So the admin's review queue updates live as users make edits on their
-- own devices (add-only; won't disturb tables already published).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'ai_corrections'
  ) then
    alter publication supabase_realtime add table ai_corrections;
  end if;
end $$;

alter table ai_corrections replica identity full;
