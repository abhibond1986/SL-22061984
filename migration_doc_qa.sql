-- ═══════════════════════════════════════════════════════════════════════════
--  migration_doc_qa.sql
--  Document Q&A (PaddleOCR ingest + retrieval-augmented answers).
--
--  Run once: Supabase → SQL Editor → New query → paste → Run.
--  Idempotent — every statement is `if not exists` / `or replace` / `drop
--  policy if exists`, so re-running is safe.
--
--  WHAT THIS SUPPORTS
--    A user uploads a PDF / DOCX / image. The file goes to Storage, the
--    PaddleOCR service extracts and chunks the text, chunks land in
--    doc_chunks, and questions + answers are logged in doc_questions so the
--    same question is answered from cache the second time and so safety
--    officers can audit what the AI told people.
--
--  WHY A SEPARATE TABLE INSTEAD OF REUSING knowledge_docs
--    knowledge_docs is the curated, plant-wide safety KB that feeds hazard
--    analysis prompts. Ad-hoc user uploads must NOT silently become plant
--    safety doctrine — an unreviewed contractor method statement would start
--    influencing every hazard assessment. Documents live here until an admin
--    explicitly promotes them (see `promoted_doc_group` below), at which point
--    they are copied into knowledge_docs through the existing verified/indexed
--    flow. Keeping them apart is a safety boundary, not just tidiness.
--
--  NOTE ON THE 42703 TRAP
--    PostgREST rejects the ENTIRE row when one column is unknown, and it
--    serves a cached schema for a minute or two after a migration. If inserts
--    fail with 42703 right after running this, that is the cache — the
--    `notify pgrst` at the bottom handles it, but give it a moment.
-- ═══════════════════════════════════════════════════════════════════════════


-- ── STEP 1 : documents ─────────────────────────────────────────────────────
-- One row per uploaded file.
create table if not exists public.doc_library (
  id              bigint generated always as identity primary key,

  -- The app generates its own ids (e.g. '1723456789012-7'), which cannot go
  -- into an identity primary key. client_id is the upsert conflict target so
  -- a retried upload updates its row instead of duplicating it — the same
  -- pattern knowledge_docs.client_id uses.
  client_id       text,

  title           text not null,
  file_name       text,
  file_kind       text,          -- 'pdf' | 'docx' | 'image' | 'text'
  file_size       int,
  storage_path    text,          -- path within the doc-library bucket
  storage_url     text,          -- public URL, convenient for re-download

  -- Extraction outcome
  page_count      int  default 0,
  ocr_page_count  int  default 0,   -- how many pages needed PaddleOCR
  char_count      int  default 0,
  chunk_count     int  default 0,
  mean_confidence real,             -- mean OCR box confidence, null if no OCR

  -- True when text came from OCR rather than an embedded text layer. OCR of a
  -- faded steel-plant photocopy is good but not perfect, so the UI must warn
  -- before anyone acts on a quoted clause. Mirrors the verified/unverified
  -- split already used for sop_scan docs.
  ocr_derived     boolean default false,
  truncated       boolean default false,  -- hit the service's page budget

  -- 'pending' | 'extracting' | 'ready' | 'failed'
  status          text default 'pending',
  error_message   text,

  -- Extracted text is kept whole as well as chunked: the UI shows a preview,
  -- and re-chunking later (better splitter, different size) then costs no OCR.
  full_text       text,

  -- Scoping / ownership. plant matches the existing plant_scope convention.
  plant           text,
  created_by      text,
  language        text default 'en',

  -- Set to the knowledge_docs.doc_group value once an admin promotes this
  -- document into the plant-wide KB. Null = not promoted.
  promoted_doc_group text,

  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- Partial unique index rather than a unique constraint: rows could carry a
-- null client_id, and several nulls would trip a unique constraint while a
-- partial index simply ignores them.
create unique index if not exists doc_library_client_id_uidx
  on public.doc_library (client_id)
  where client_id is not null;

create index if not exists doc_library_created_by_idx on public.doc_library (created_by);
create index if not exists doc_library_plant_idx      on public.doc_library (plant);
create index if not exists doc_library_status_idx     on public.doc_library (status);
create index if not exists doc_library_created_at_idx on public.doc_library (created_at desc);


-- ── STEP 2 : chunks ────────────────────────────────────────────────────────
-- The retrievable unit. One row per clause / section, matching the existing
-- "one knowledge_docs row per SOP clause" convention.
create table if not exists public.doc_chunks (
  id            bigint generated always as identity primary key,

  -- Cascade: deleting a document must not leave orphan chunks that keep
  -- turning up in search results with no source to cite.
  document_id   bigint not null
                  references public.doc_library (id) on delete cascade,
  doc_client_id text,          -- denormalised, saves a join on the hot path

  chunk_index   int not null,  -- order within the document
  content       text not null,

  -- Citation metadata. Without these an answer can only say "the document
  -- says", which is useless to a safety officer who has to act on it.
  clause_no     text,
  heading       text,
  page_from     int,
  page_to       int,
  char_count    int,

  -- Excluded from retrieval when false, so an admin can suppress a badly
  -- OCR'd chunk without deleting the document.
  indexed       boolean default true,

  created_at    timestamptz default now()
);

create index if not exists doc_chunks_document_idx
  on public.doc_chunks (document_id, chunk_index);

create index if not exists doc_chunks_client_idx
  on public.doc_chunks (doc_client_id)
  where doc_client_id is not null;

create index if not exists doc_chunks_indexed_idx on public.doc_chunks (indexed);

-- ── Full-text search ──────────────────────────────────────────────────────
-- Postgres FTS, NOT pgvector. Deliberate: this project has no embedding
-- infrastructure, and retrieval elsewhere is keyword + synonym scoring
-- (LocalDB.searchKnowledge). Safety queries are also heavy on exact tokens
-- that embeddings blur — "LOTO", "SOP 4.2.1", "H2S", "EOT crane" — where
-- lexical matching genuinely outperforms semantic similarity. 'english'
-- config gives stemming so "isolating" matches "isolate".
alter table public.doc_chunks
  add column if not exists content_tsv tsvector
  generated always as (
    to_tsvector('english', coalesce(heading, '') || ' ' || coalesce(content, ''))
  ) stored;

create index if not exists doc_chunks_tsv_idx
  on public.doc_chunks using gin (content_tsv);

-- Trigram index for fuzzy matching on misspellings and OCR errors, which are
-- common enough in scanned SOPs to matter ("hetmet", "cyIinder").
create extension if not exists pg_trgm;
create index if not exists doc_chunks_content_trgm_idx
  on public.doc_chunks using gin (content gin_trgm_ops);


-- ── STEP 3 : questions & answers ───────────────────────────────────────────
-- An audit trail and a cache. The audit half matters most: if the AI gave a
-- wrong answer about an isolation procedure, there must be a record of exactly
-- what was asked, what was answered, and which chunks were cited.
create table if not exists public.doc_questions (
  id            bigint generated always as identity primary key,
  client_id     text,

  document_id   bigint references public.doc_library (id) on delete cascade,
  doc_client_id text,

  question      text not null,
  answer        text,

  -- Which chunks the answer was built from, as a JSON array of
  -- {chunkId, clauseNo, pageFrom, score}. Enables "show me the source".
  sources       jsonb default '[]'::jsonb,

  -- Lowercased, whitespace-collapsed question, used as the cache key so
  -- "What PPE?" and "what  ppe?" hit the same cached answer.
  question_key  text,

  model         text,          -- e.g. 'gemini-2.0-flash'
  answered_by   text,          -- 'gemini' | 'extractive' | 'cache'
  latency_ms    int,
  chunk_count   int,           -- how many chunks were fed to the model

  -- null = no feedback, true = helpful, false = not helpful. Feeds the same
  -- review loop as ai_corrections.
  helpful       boolean,
  asked_by      text,
  plant         text,

  created_at    timestamptz default now()
);

create index if not exists doc_questions_document_idx
  on public.doc_questions (document_id, created_at desc);

create index if not exists doc_questions_cache_idx
  on public.doc_questions (document_id, question_key);

create index if not exists doc_questions_asked_by_idx on public.doc_questions (asked_by);

create unique index if not exists doc_questions_client_id_uidx
  on public.doc_questions (client_id)
  where client_id is not null;


-- ── STEP 4 : retrieval function ────────────────────────────────────────────
-- Ranked chunk search, run in the database so we never ship the whole document
-- to the client just to score it.
--
-- Scoring mirrors LocalDB.searchKnowledge so answers are consistent between
-- the offline and online paths:
--   * ts_rank_cd on the FTS vector           — the main lexical signal
--   * +0.35 if the heading matches           — headings are strong topic labels
--   * +0.50 if the whole phrase appears      — exact-phrase hits are gold
--   * +0.15 similarity() fuzzy fallback      — catches OCR typos
-- websearch_to_tsquery is used because it never throws on user punctuation,
-- unlike to_tsquery which errors on a stray '&' and would 500 the request.
create or replace function public.search_doc_chunks(
  p_document_id bigint,
  p_query       text,
  p_limit       int default 6
)
returns table (
  id         bigint,
  content    text,
  clause_no  text,
  heading    text,
  page_from  int,
  page_to    int,
  score      real
)
language sql
stable
as $$
  with q as (
    select
      websearch_to_tsquery('english', coalesce(p_query, '')) as tsq,
      lower(trim(coalesce(p_query, '')))                     as raw
  )
  select
    c.id,
    c.content,
    c.clause_no,
    c.heading,
    c.page_from,
    c.page_to,
    (
      ts_rank_cd(c.content_tsv, q.tsq)
      + case when c.heading is not null and q.raw <> ''
                  and lower(c.heading) like '%' || q.raw || '%'
             then 0.35 else 0 end
      + case when q.raw <> '' and lower(c.content) like '%' || q.raw || '%'
             then 0.50 else 0 end
      + (0.15 * similarity(lower(c.content), q.raw))
    )::real as score
  from public.doc_chunks c
  cross join q
  where c.document_id = p_document_id
    and c.indexed is true
    -- Keep fuzzy/phrase matches that the tsquery alone would miss, but still
    -- require SOME signal so we don't return the whole document ranked 0.
    and (
      c.content_tsv @@ q.tsq
      or (q.raw <> '' and lower(c.content) like '%' || q.raw || '%')
      or (q.raw <> '' and similarity(lower(c.content), q.raw) > 0.12)
    )
  order by score desc, c.chunk_index asc
  limit greatest(1, least(coalesce(p_limit, 6), 20));
$$;


-- ── STEP 5 : Row Level Security ────────────────────────────────────────────
-- Same posture as ai_runs / ai_corrections / knowledge_docs: the app uses the
-- anon (publishable) key and access is gated by the app's own login, not
-- Supabase Auth.
--
-- BE AWARE: `using (true)` on select means anyone holding the publishable key
-- can read every uploaded document. That is consistent with the rest of this
-- project, but it is a real consideration here because users upload arbitrary
-- files — a contractor could upload a commercially sensitive method statement
-- and it would be readable by any authenticated app user. If that matters,
-- migrate to Supabase Auth and change the read policies to
--   using (created_by = auth.jwt() ->> 'email')
-- for doc_library and a matching `exists` subquery for doc_chunks.
alter table public.doc_library   enable row level security;
alter table public.doc_chunks    enable row level security;
alter table public.doc_questions enable row level security;

drop policy if exists "doc_library read"   on public.doc_library;
drop policy if exists "doc_library insert" on public.doc_library;
drop policy if exists "doc_library update" on public.doc_library;
drop policy if exists "doc_library delete" on public.doc_library;

create policy "doc_library read"   on public.doc_library for select using (true);
create policy "doc_library insert" on public.doc_library for insert with check (true);
create policy "doc_library update" on public.doc_library for update using (true);
create policy "doc_library delete" on public.doc_library for delete using (true);

drop policy if exists "doc_chunks read"   on public.doc_chunks;
drop policy if exists "doc_chunks insert" on public.doc_chunks;
drop policy if exists "doc_chunks update" on public.doc_chunks;
drop policy if exists "doc_chunks delete" on public.doc_chunks;

create policy "doc_chunks read"   on public.doc_chunks for select using (true);
create policy "doc_chunks insert" on public.doc_chunks for insert with check (true);
create policy "doc_chunks update" on public.doc_chunks for update using (true);
create policy "doc_chunks delete" on public.doc_chunks for delete using (true);

drop policy if exists "doc_questions read"   on public.doc_questions;
drop policy if exists "doc_questions insert" on public.doc_questions;
drop policy if exists "doc_questions update" on public.doc_questions;
drop policy if exists "doc_questions delete" on public.doc_questions;

create policy "doc_questions read"   on public.doc_questions for select using (true);
create policy "doc_questions insert" on public.doc_questions for insert with check (true);
create policy "doc_questions update" on public.doc_questions for update using (true);
create policy "doc_questions delete" on public.doc_questions for delete using (true);

-- The retrieval function must be callable with the publishable key.
grant execute on function public.search_doc_chunks(bigint, text, int) to anon, authenticated;


-- ── STEP 6 : Storage bucket ────────────────────────────────────────────────
-- Holds the original uploads so a document can be re-read without re-upload.
-- Public, matching the existing incident-images bucket. Filenames are
-- timestamp-prefixed by the client, so they are hard to guess but NOT secret.
insert into storage.buckets (id, name, public)
select 'doc-library', 'doc-library', true
where not exists (select 1 from storage.buckets where id = 'doc-library');

drop policy if exists "doc-library read"   on storage.objects;
drop policy if exists "doc-library insert" on storage.objects;
drop policy if exists "doc-library update" on storage.objects;
drop policy if exists "doc-library delete" on storage.objects;

create policy "doc-library read"
  on storage.objects for select
  using (bucket_id = 'doc-library');

create policy "doc-library insert"
  on storage.objects for insert
  with check (bucket_id = 'doc-library');

-- Update is needed for upsert:true re-uploads, which is the fallback path the
-- client takes when an insert-only upload fails.
create policy "doc-library update"
  on storage.objects for update
  using (bucket_id = 'doc-library');

create policy "doc-library delete"
  on storage.objects for delete
  using (bucket_id = 'doc-library');


-- ── STEP 7 : updated_at trigger ────────────────────────────────────────────
create or replace function public.touch_doc_library()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists doc_library_touch on public.doc_library;
create trigger doc_library_touch
  before update on public.doc_library
  for each row execute function public.touch_doc_library();


-- ── STEP 8 : Make PostgREST notice the new tables immediately ──────────────
-- Without this the API keeps serving its cached schema and the client still
-- sees 42703 / 404 for a minute or two after the migration.
notify pgrst, 'reload schema';


-- ═══════════════════════════════════════════════════════════════════════════
--  VERIFY
--
--  1) Tables and the function exist:
--
--     select table_name from information_schema.tables
--      where table_name in ('doc_library','doc_chunks','doc_questions');
--
--     select routine_name from information_schema.routines
--      where routine_name = 'search_doc_chunks';
--
--  2) Retrieval works end to end (should return the PPE row, score > 0):
--
--     with d as (
--       insert into public.doc_library (client_id, title, status)
--       values ('verify-doc-1', 'Verify SOP', 'ready') returning id
--     )
--     insert into public.doc_chunks (document_id, chunk_index, content, clause_no)
--     select d.id, 0,
--            'Operators shall wear aluminised proximity suits and heat '
--            'resistant gloves before approaching the ladle.', '4.2'
--       from d;
--
--     select clause_no, score, left(content, 50)
--       from public.search_doc_chunks(
--              (select id from public.doc_library where client_id='verify-doc-1'),
--              'what PPE is required for the ladle', 5);
--
--     -- clean up
--     delete from public.doc_library where client_id = 'verify-doc-1';
--
--  3) Bucket exists:
--
--     select id, public from storage.buckets where id = 'doc-library';
-- ═══════════════════════════════════════════════════════════════════════════
