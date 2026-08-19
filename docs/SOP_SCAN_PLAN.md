# SOP / SMP camera scanning → Knowledge Base

**Status:** plan, not built. Written 2026-08-19.
**Decisions taken by the user:** any user may scan (no admin gate), OCR is
device-first with AI fallback, storage keeps both raw OCR text and an AI
structured summary.

The goal: point the phone camera at a printed SOP or SMP, read the text, put it
into the Knowledge Base, and have the AI chat answer questions from it — with a
citation, so an answer can be traced back to a clause.

---

## 1. What already exists, and where the gap actually is

Worth being precise about this, because most of the machinery is already here and
the temptation is to build a parallel system next to it.

**KB write path.** `LocalDB.addKnowledgeDoc({title, content, source})` appends to
a list held as one JSON blob in `SharedPreferences` under `_kKbDocs`, then calls
`_bumpKb()` which increments the KB revision. Admin's PDF/DOCX upload
(`_uploadKbDocument` in `admin_screen.dart:7093`) extracts text, slices it with
`_chunkTextForKb` at 2500 chars on sentence boundaries, and writes one KB entry
per chunk titled `"<file> — Section N"`.

**KB read path.** `LocalDB.searchKnowledge(query, limit, snippetChars)`
(`local_db.dart:1044`) scores every doc by exact word hits, synonym hits at half
weight, a +10 full-phrase bonus, +5 for a title match, and fuzzy 1-char variants.
`KnowledgeService.getContextForPrompt` wraps that for AI scanning; `chat_tab.dart:302`
calls `searchKnowledge` directly with `limit: 5, snippetChars: 700`.

**Sync.** `SyncService.pushKbDocs(docs)` → `SupabaseService.addKnowledgeDoc` per
doc → `knowledge_docs` table.

**The gap.** `pdf_kb_extractor.dart` is a conditional export: web gets pdf.js,
mobile gets `pdf_kb_extractor_stub.dart` whose `extractTextFromPdf` returns `''`.
So on Android and iOS there is no way at all to get a document into the KB today.
And even on web, a scanned SOP is an image-only PDF, so pdf.js returns nothing —
`_uploadKbDocument` already has the toast for it: *"No text found in document. It
may be image-based."* Camera OCR closes both holes at once.

---

## 2. Three things to fix before adding scanning

These are pre-existing, and scanning makes each one materially worse. Fix them
first or the feature will look broken for reasons that have nothing to do with OCR.

### 2a. `pushKbDocs` re-inserts the entire KB on every upload

`admin_screen.dart:7175` calls `SyncService.pushKbDocs(updatedDocs)` with the
**whole** doc list after an upload. `SupabaseService.addKnowledgeDoc` does a plain
`insert`, not an upsert, and does not send `id`. So every upload duplicates every
document already in `knowledge_docs`.

Today that is a slow leak. A 40-page SOP is roughly 60 new chunks, and pushing the
full list afterwards re-inserts everything that came before — the growth is
quadratic, and duplicated chunks then compete with each other in retrieval and eat
the top-5 slots with copies of one passage.

Fix: send `id` in the insert payload, make it the conflict target, use
`.upsert(..., onConflict: 'id')`, and change call sites to push only the new docs.

### 2b. `fetchKnowledgeDocs` never selects `id`

`supabase_service.dart:619` selects `'title, content, source'`. Pulled docs
therefore arrive with no identity, so they cannot be de-duplicated against local
docs, and `SupabaseService.deleteKnowledgeDoc(id)` can never be called for a doc
that came from the server — there is no id to pass it. Add `id` (and the new
columns from §5) to the select.

### 2c. The KB is one `SharedPreferences` JSON blob, decoded on every search

`getKnowledgeDocs()` does a full `jsonDecode` of the entire KB, and
`searchKnowledge` calls it every time. With the seeded set that is cheap. With a
few scanned SOPs — hundreds of KB of text — it becomes a full parse per query, per
AI call, per chat message.

Fix cheaply: memoise the parsed list in `LocalDB`, keyed on the existing KB
revision counter, and drop the cache in `_bumpKb()`. The revision mechanism is
already there for exactly this class of problem (see the comment at
`local_db.dart:40` about "add knowledge, then scan" using stale knowledge).

Only if it still hurts: move KB content out of `SharedPreferences` into a file via
`path_provider`, the way `ImageStorage` already handles images.

---

## 3. Capture — a multi-page scan screen

New file `lib/screens/sop_scan_screen.dart`.

An SOP is never one page, so the screen is a page list, not a single shot. Camera
button appends a page; each page shows as a thumbnail with retake, delete and
reorder; a running page count; then "Read pages". Cap it (30 pages is a sane
first limit) and say why when the cap is hit, because every page costs an OCR
pass and, on the fallback path, AI quota.

Reuse the downscale logic in `ai_scan_tab.dart:266` — it decodes, resizes the long
edge to 900px and re-encodes. **Do not copy it.** Lift it into
`lib/utils/image_prep.dart` and have both call it. Note the existing comment there
about re-encoding even small images to compress them; keep that behaviour.

One difference from hazard photos: OCR wants more resolution than hazard detection
does. 900px on the long edge is too low to read 10pt body text reliably. Use a
separate, higher `maxEdge` for OCR (1600–2000px) and keep 900px for hazard scans.
This is the single highest-leverage knob on OCR accuracy — get it wrong and every
downstream tier looks bad.

Store captured pages under `ImageStorage` (it already writes to a directory and
keeps an index) rather than inline base64, so a 20-page scan does not land in
`SharedPreferences`.

---

## 4. OCR — device first, AI fallback

New service `lib/services/sop_ocr_service.dart`, one public entry:

```dart
Future<PageOcr> readPage(Uint8List pageBytes, {required int pageNo});
// PageOcr { String text; String engine; double confidence; bool ok; String? error; }
```

### Tier 1 — on-device ML Kit (mobile only)

Add `google_mlkit_text_recognition`. It is Android/iOS only, so it **must** sit
behind the same conditional-export pattern the repo already uses for pdf.js —
this is an established convention here, follow it rather than inventing a second
one:

```
lib/services/sop_ocr_mlkit.dart        // router: export stub if dart.library.html
lib/services/sop_ocr_mlkit_stub.dart   // web: isAvailable => false, never throws
lib/services/sop_ocr_mlkit_impl.dart   // mobile: real TextRecognizer
```

The stub must report unavailable and return empty, **not** throw. A thrown
`MissingPluginException` on web would surface as a crash dialog instead of a quiet
fallback.

Two practical notes: ML Kit's Latin model adds roughly 10 MB to the APK if
bundled, and it may raise your `minSdkVersion` — check `android/app/build.gradle`
against the plugin's requirement before you commit, since CI is the first place
anything compiles.

### Tier 2 — the AI proxy you already have

Do **not** route this through `GeminiVision.analyseImageBytes`. That method carries
the hazard prompt, hazard-shaped JSON parsing, the free-quota ledger
(`_recordFreeUsage`), and a result cache keyed for hazard analysis. Pushing an OCR
job through it would pollute all four, and `_isValidResult` would reject a plain
text response.

Instead add a sibling entry point that reuses only the plumbing worth reusing: the
key resolution (`_configuredOpenRouterKeys`, `NaraVision.getApiKey`), the Apps
Script proxy URL, the 2-second `_minCallInterval` throttle, and the
`kAttemptTimeout` / `_kTier1Budget` latency budgets. Those budgets exist because a
45-second timeout on a reasoning model once made scanning feel broken — an OCR
pass over 20 pages must respect the same discipline, and should show per-page
progress rather than one long spinner.

Prompt for this tier: return the page's text verbatim, preserve numbered clause
structure and table rows, transcribe nothing that is not visible, and emit an
explicit marker for unreadable regions. That last instruction matters — a vision
model asked to "read an SOP" will happily invent plausible SOP language for a
blurred paragraph, and invented safety text in the KB is the worst possible
failure mode for this app.

### The quality gate between the tiers

"Device OCR looked too sparse" has to be a number or the fallback fires at random.
Trigger Tier 2 when any of these hold: fewer than 200 characters recognised, or
the alphabetic character ratio is below 0.5 (garbage output tends to be symbol
soup), or fewer than 20 word-like tokens, or ML Kit reported unavailable. Log which
gate fired — you will want to tune these against real plant documents, and without
the log you are guessing.

### Failure handling

Mirror the rule already written into `gemini_vision.dart`: **a failed read produces
nothing, not a plausible-looking placeholder.** No "[content unavailable]" text
entering the KB, no partial page silently dropped. A page that both tiers fail on
is shown in the review list as failed, with retake offered, and it is excluded from
the summary pass. Do not cache a failed OCR result.

---

## 5. Storage — raw plus AI summary

### The summarisation pass

After all pages read, concatenate the raw text and make one AI call asking for
structured JSON:

```json
{
  "sop_number": "SOP/BF/14",
  "title": "Hot metal ladle handling",
  "revision": "Rev 3",
  "issue_date": "2024-06-01",
  "department": "Blast Furnace",
  "scope": "...",
  "ppe": ["aluminized suit", "face shield"],
  "key_limits": ["ladle preheat min 800 °C", "5 m exclusion zone at tapping"],
  "clauses": [{ "clause_no": "6.2", "heading": "...", "text": "...", "page": 4 }]
}
```

Every field must be nullable and the parse must tolerate a missing one — plant SOPs
are inconsistently formatted and a strict parser will reject most real documents.
Reuse the existing tolerant JSON extraction (`GeminiVision._parseAIResponse` already
handles fenced and prose-wrapped JSON) rather than a bare `jsonDecode`.

### What gets written

Two kinds of entry, distinguished by `source`:

`sop_scan_raw` — one entry holding the full OCR text, for audit and for re-running
the summary later without re-scanning. **Excluded from retrieval.**

`sop_scan` — one entry per clause (or per small group of clauses), titled
`"<sop_number> <title> — clause <n>"`, carrying the clause text plus the SOP header
fields. These are what retrieval sees.

**The exclusion is not optional, and it is the trap in this whole design.**
`searchKnowledge` scores by raw keyword hit count, so the long raw-text entry will
almost always outscore the tidy clause entries drawn from it — the same words, more
of them. Ship without the exclusion and every SOP answer gets a 700-character
mid-sentence slice of unstructured OCR instead of the clause. Implement it as an
`indexed` flag on the doc checked inside `searchKnowledge` itself, not as a filter
at each call site, because there are already several call sites
(`chat_tab`, `KnowledgeService`, `near_miss_tab`, two in `gemini_vision`) and a
future one will forget.

### Schema

```sql
-- knowledge_docs: SOP scan support
alter table public.knowledge_docs add column if not exists doc_group   text;
alter table public.knowledge_docs add column if not exists sop_number  text;
alter table public.knowledge_docs add column if not exists clause_no   text;
alter table public.knowledge_docs add column if not exists page_from   int;
alter table public.knowledge_docs add column if not exists page_to     int;
alter table public.knowledge_docs add column if not exists plant       text;
alter table public.knowledge_docs add column if not exists created_by  text;
alter table public.knowledge_docs add column if not exists verified    boolean default false;
alter table public.knowledge_docs add column if not exists indexed     boolean default true;

create index if not exists knowledge_docs_group_idx on public.knowledge_docs (doc_group);

notify pgrst, 'reload schema';
```

`doc_group` ties all clauses from one scan together so the set can be deleted,
re-summarised or shown as one document in the UI.

**Run this migration before shipping the client.** PostgREST rejects the *entire
row* when one column is unknown — this is the exact `42703` failure that broke
incident upserts, and `addKnowledgeDoc` has **no** schema-gap guard (only
`upsertIncident` got one). So a client that sends `sop_number` against an
un-migrated table silently saves nothing to the cloud. Either run the SQL first, or
port the schema-gap retry from `upsertIncident` to `addKnowledgeDoc` — and if you
port it, keep the three regex fixes noted there: Postgres also emits the quoted
`column "x" does not exist` form and the `public.knowledge_docs.x` qualified form,
and `42P01` must return null early or the table name gets stripped as a column.

Verify afterwards the same way:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "$SUPABASE_URL/rest/v1/knowledge_docs?select=sop_number,clause_no,doc_group&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
```

---

## 6. Trust tiers in the prompt

`KnowledgeService.getContextForPrompt` currently labels every KB doc as
*"authoritative for this plant and OVERRIDE any general knowledge that conflicts
with them"*. With open write access, that sentence now applies to anything any user
photographs.

Split the injected context into two labelled blocks. Admin-uploaded docs keep the
existing authoritative wording. Scanned docs get their own block: scanned from a
plant document by *name* on *date*, not yet verified by the safety admin, may
contain OCR errors — usable and citable, but say it is unverified, and where it
conflicts with an admin-uploaded document or a statutory reference, the
admin-uploaded one wins.

Gate it on one constant so the decision is reversible in a single line:

```dart
static const bool kScansAreAuthoritative = false;
```

Everything must go through `resolvedExpertPrompt()` as today — the raw
`expertSystemPrompt` still holds the unresolved `{{WSA_CAUSES}}` placeholder and
must never reach a model directly.

And remember `GeminiVision.invalidateKbContext()`: `_kbContextCache` is memoised
against `_kbContextCacheRev`, so a scan that adds docs without invalidating leaves
the next hazard analysis running on the pre-scan KB.

---

## 7. Chat citation

`chat_tab.dart:302` already retrieves 5 docs at 700 chars. Two changes: pass the
clause metadata into the prompt alongside the snippet, and instruct the model to
cite in the form `SOP/BF/14 clause 6.2` whenever an answer rests on a scanned doc,
plus a visible "unverified scan" note when it does. Render the citation as a chip
under the answer that opens the stored clause — the retrieval is only trustworthy
to the user if they can check it.

If retrieval quality disappoints once several SOPs are loaded, the upgrade is
embeddings rather than more keyword tuning; see the RAG item in §10.

---

## 8. Admin surface

Even with open writes, admins need a view: the existing KB doc list filtered to
`source = 'sop_scan'`, grouped by `doc_group`, showing who scanned it and when,
with delete-whole-document and a "mark verified" action that flips `verified` and
promotes the doc into the authoritative block from §6. This is a filter and two
buttons over UI that already exists, and it is what makes the open-write decision
recoverable.

---

## 9. Files to touch

| File | Change |
|---|---|
| `lib/screens/sop_scan_screen.dart` | new — multi-page capture, page list, progress, review |
| `lib/services/sop_ocr_service.dart` | new — tier orchestration, quality gate, summary pass |
| `lib/services/sop_ocr_mlkit{,_stub,_impl}.dart` | new — conditional-export ML Kit wrapper |
| `lib/utils/image_prep.dart` | new — downscale helper lifted from `ai_scan_tab.dart:266` |
| `lib/services/local_db.dart` | `addKnowledgeDoc` gains new fields; `searchKnowledge` honours `indexed`; memoise parsed KB |
| `lib/services/knowledge_service.dart` | two-tier trust blocks, `kScansAreAuthoritative` |
| `lib/services/supabase_service.dart` | `fetchKnowledgeDocs` selects `id` + new columns; `addKnowledgeDoc` → upsert on `id` |
| `lib/services/sync_service.dart` | `pushKbDocs` pushes deltas, not the whole list |
| `lib/screens/chat_tab.dart` | citation metadata + unverified note |
| `lib/screens/admin_screen.dart` | scanned-docs group view, verify/delete |
| `lib/screens/home_tab.dart` | entry point tile |
| `migration_sop_scan.sql` | new — §5 SQL |
| `pubspec.yaml` | `google_mlkit_text_recognition` |
| `STATUS.md` | record the migration and whether it has been run |

---

## 10. Suggested order

1. §2 fixes (duplicate push, missing `id`, KB parse cache). Independent of OCR,
   and they are load-bearing for everything after.
2. Migration + `addKnowledgeDoc`/`fetchKnowledgeDocs` fields, verified by curl.
3. Capture screen writing raw pages only — no OCR yet. Proves the camera, storage
   and page-management UX in isolation.
4. Tier 2 (AI proxy) OCR first, not Tier 1. It works on web where you can iterate
   fastest, and it establishes the `PageOcr` contract.
5. Tier 1 ML Kit behind the router, plus the quality gate.
6. Summary pass, `indexed` exclusion, trust tiers.
7. Chat citation, then the admin group view.

Ship after step 4 if you want it in users' hands early — an AI-only OCR path is a
complete feature; ML Kit is a latency, cost and offline improvement on top.

---

## 11. Traps carried over from previous sessions

No Flutter SDK exists in the agent sandbox, so **nothing an agent writes here has
been compiled.** CI (Flutter 3.19.6) is the first real compile — avoid Dart 3
record and pattern-switch syntax. Keep `.gitattributes` intact; a Windows checkout
once flipped the tree to CRLF and turned a 22-file diff into 171 files.

New screens must respect the readability rules: no font size below 10px, and use
the `sl.*Text` getters rather than bare `AppColors.amber/red/green/accent` for
text and icons (amber is 2.15:1 on white). Run `python3 tools/audit_contrast.py
--strict` before committing.

Offline behaviour must be honest. Device OCR works with no network; the AI summary
does not. When offline, save the raw pages and the raw OCR text, mark the document
"summary pending", and queue it — do not synthesise a summary locally. This is the
same principle as the offline hazard scan returning no hazards: **the app must
never present generated content as if it came from the document.**
