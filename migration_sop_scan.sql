-- ═══════════════════════════════════════════════════════════════════════════
--  migration_sop_scan.sql
--  SOP / SMP camera-scan support for the knowledge base.
--
--  Run once: Supabase → SQL Editor → New query → paste → Run.
--  Idempotent — every statement is `if not exists` / `or replace`, so
--  re-running is safe.
--
--  RUN THIS BEFORE SHIPPING A CLIENT THAT SCANS SOPs.
--  PostgREST rejects the ENTIRE row when one column is unknown (error 42703),
--  which is how the incident workflow migration silently discarded closure data
--  for a while. SupabaseService.addKnowledgeDoc now carries the same
--  schema-gap guard as upsertIncident — it learns the missing column from the
--  error, drops it and retries — so an un-migrated server degrades to "doc saved
--  without its scan metadata" instead of "nothing saved". That is a safety net,
--  not a substitute: the metadata genuinely does not persist until this runs.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Stable client-side key ──────────────────────────────────────────────
-- knowledge_docs.id is `bigint generated always as identity`, so it cannot hold
-- the app's own doc ids (which look like `1723456789012-7`) and rejects an
-- explicit value outright. client_id exists purely to give the upsert a
-- conflict target, so re-pushing a doc updates it instead of duplicating it.
alter table public.knowledge_docs
  add column if not exists client_id text;

-- Partial unique index, not a plain unique constraint: rows written before this
-- migration have client_id = null, and several nulls would violate a NOT NULL
-- unique constraint while a partial index simply ignores them.
create unique index if not exists knowledge_docs_client_id_uidx
  on public.knowledge_docs (client_id)
  where client_id is not null;

-- ── 2. Scan metadata ──────────────────────────────────────────────────────
alter table public.knowledge_docs add column if not exists doc_group  text;
alter table public.knowledge_docs add column if not exists sop_number text;
alter table public.knowledge_docs add column if not exists clause_no  text;
alter table public.knowledge_docs add column if not exists page_from  int;
alter table public.knowledge_docs add column if not exists page_to    int;
alter table public.knowledge_docs add column if not exists plant      text;
alter table public.knowledge_docs add column if not exists created_by text;

-- Admin-uploaded documents are authoritative; user scans start unverified and
-- an admin promotes them. KnowledgeService puts the two into separately
-- labelled blocks in the AI prompt, so this column decides how much weight the
-- model gives the text.
alter table public.knowledge_docs
  add column if not exists verified boolean default false;

-- false = excluded from retrieval. Used for the raw full-text copy of a scan,
-- which would otherwise outscore the clause entries derived from it (scoring is
-- by keyword hit count, and the raw dump has the same words but far more of
-- them). Defaults true so every pre-existing doc stays searchable.
alter table public.knowledge_docs
  add column if not exists indexed boolean default true;

-- ── 3. Indexes ────────────────────────────────────────────────────────────
-- doc_group ties all the entries of one scan together for group delete/verify.
create index if not exists knowledge_docs_group_idx
  on public.knowledge_docs (doc_group)
  where doc_group is not null;

create index if not exists knowledge_docs_indexed_idx
  on public.knowledge_docs (indexed);

-- ── 4. Backfill ───────────────────────────────────────────────────────────
-- Existing rows predate the scan feature: they are admin-loaded content, so
-- they are verified and searchable.
update public.knowledge_docs
   set verified = true
 where verified is null
   and coalesce(source, '') not like 'sop_scan%';

update public.knowledge_docs
   set indexed = true
 where indexed is null;

-- ── 5. Make PostgREST notice the new columns immediately ──────────────────
-- Without this the API keeps serving its cached schema and the client still
-- sees 42703 for a minute or two after the migration.
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
--  VERIFY
--
--  200 = applied. A 42703 in the body = not applied.
--
--    curl -s -o /dev/null -w '%{http_code}\n' \
--      "$SUPABASE_URL/rest/v1/knowledge_docs?select=client_id,sop_number,clause_no,doc_group,verified,indexed&limit=1" \
--      -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
--
--  Or in the SQL editor:
--
--    select column_name, data_type
--      from information_schema.columns
--     where table_name = 'knowledge_docs'
--     order by ordinal_position;
-- ═══════════════════════════════════════════════════════════════════════════

-- ── One-off cleanup: duplicate rows from the old full-KB push ─────────────
-- Before the delta push and the upsert key, every KB upload re-inserted every
-- row already on the server. If knowledge_docs is full of duplicates, this
-- keeps the oldest of each identical (title, content) pair. Read it, then
-- uncomment deliberately — it deletes data.
--
-- with ranked as (
--   select id,
--          row_number() over (
--            partition by title, content
--            order by created_at, id
--          ) as rn
--     from public.knowledge_docs
-- )
-- delete from public.knowledge_docs
--  where id in (select id from ranked where rn > 1);
