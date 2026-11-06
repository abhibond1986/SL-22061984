-- ════════════════════════════════════════════════════════════════════════
--  migration_kb_client_id_unique.sql            (2026-11-06)
--
--  FIXES: browser console flooded with
--    POST …/rest/v1/knowledge_docs?on_conflict=client_id  400 (Bad Request)
--
--  WHY: migration_sop_scan.sql (and migration_doc_qa.sql) made client_id
--  unique with a PARTIAL index — `… where client_id is not null`. The app
--  writes with upsert(onConflict: 'client_id'), i.e. ON CONFLICT (client_id).
--  PostgreSQL only uses a partial index as a conflict target when the
--  statement repeats the index's WHERE predicate, and PostgREST never sends
--  one, so every write fails with
--    42P10: there is no unique or exclusion constraint matching the
--           ON CONFLICT specification
--  Nothing was ever marked synced, so the app re-sent the whole knowledge
--  library on every launch.
--
--  The partial index was chosen because "several nulls would trip a unique
--  constraint". They do not: a PostgreSQL UNIQUE constraint treats NULLs as
--  distinct, so any number of old rows with client_id = null are allowed.
--
--  THE APP ALREADY WORKS WITHOUT THIS (it falls back to update-then-insert
--  after the first 42P10), but that costs one 400 per session and two round
--  trips per document. Run this once in Supabase → SQL Editor to restore the
--  one-trip upsert. Safe to run more than once.
-- ════════════════════════════════════════════════════════════════════════

begin;

-- ── 1. knowledge_docs ────────────────────────────────────────────────────
-- Any duplicate client_id would block the constraint. Keep the newest row of
-- each (highest id), delete the older copies.
delete from public.knowledge_docs a
 using public.knowledge_docs b
 where a.client_id is not null
   and a.client_id = b.client_id
   and a.id < b.id;

drop index if exists public.knowledge_docs_client_id_uidx;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'knowledge_docs_client_id_key'
       and conrelid = 'public.knowledge_docs'::regclass
  ) then
    alter table public.knowledge_docs
      add constraint knowledge_docs_client_id_key unique (client_id);
  end if;
end $$;

-- ── 2. doc_library / doc_questions (Doc Q&A) — same defect, same fix ─────
do $$
begin
  if to_regclass('public.doc_library') is not null then
    delete from public.doc_library a
     using public.doc_library b
     where a.client_id is not null
       and a.client_id = b.client_id
       and a.id < b.id;
    drop index if exists public.doc_library_client_id_uidx;
    if not exists (
      select 1 from pg_constraint
       where conname = 'doc_library_client_id_key'
         and conrelid = 'public.doc_library'::regclass
    ) then
      alter table public.doc_library
        add constraint doc_library_client_id_key unique (client_id);
    end if;
  end if;

  if to_regclass('public.doc_questions') is not null then
    delete from public.doc_questions a
     using public.doc_questions b
     where a.client_id is not null
       and a.client_id = b.client_id
       and a.id < b.id;
    drop index if exists public.doc_questions_client_id_uidx;
    if not exists (
      select 1 from pg_constraint
       where conname = 'doc_questions_client_id_key'
         and conrelid = 'public.doc_questions'::regclass
    ) then
      alter table public.doc_questions
        add constraint doc_questions_client_id_key unique (client_id);
    end if;
  end if;
end $$;

commit;

-- ── 3. Make PostgREST see the new constraint immediately ─────────────────
notify pgrst, 'reload schema';

-- ── 4. Check (should return 3 rows, contype = 'u') ───────────────────────
-- select conrelid::regclass, conname, contype
--   from pg_constraint
--  where conname in ('knowledge_docs_client_id_key',
--                    'doc_library_client_id_key',
--                    'doc_questions_client_id_key');
