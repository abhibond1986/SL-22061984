# Document Q&A — setup guide

Upload a PDF, Word file or photo of a printed page; ask questions about it; get
answers that quote the document and cite the clause and page.

Four pieces have to be in place. None of them cost money.

```
Flutter Web  ──upload──►  OCR service (PaddleOCR, Python)  ──text + clauses──┐
     │                                                                       │
     ├──file + chunks──►  Supabase Storage + Postgres  ◄──retrieval (FTS)─────┘
     │
     └──question + extracts──►  Apps Script  ──►  Gemini Flash  ──►  answer + sources
```

The Gemini call goes through Apps Script on purpose. Google detected this
project's API keys in browser network traffic and **disabled them**, which is why
`lib/services/api_keys.dart` and `lib/services/gemini_direct.dart` are
deliberate no-op stubs. Do not add a client-side Gemini call for this feature.

---

## Step 1 — Deploy the OCR service

Full instructions, including the Hugging Face Spaces specifics, are in
[`ocr_service/README.md`](ocr_service/README.md). The short version: create a
Docker Space, upload `Dockerfile`, `app.py`, `extractors.py`, `chunker.py` and
`requirements.txt`, set `ALLOWED_ORIGINS` to your app's domain, and wait ~10–15
minutes for the first build.

You end up with a URL like `https://yourname-safetylens-ocr.hf.space`. Open it in
a browser and confirm you get JSON rather than a loading page.

## Step 2 — Run the database migration

Supabase → SQL Editor → New query → paste all of
[`migration_doc_qa.sql`](migration_doc_qa.sql) → Run.

> **This migration has not been executed against a live database yet.** It could
> not be tested locally — the build sandbox has no Postgres and no root access to
> install one — so treat the first run as the real test. It is written to be
> idempotent (`if not exists` / `or replace` / `drop policy if exists`) so
> re-running after a failure is safe, and the `VERIFY` block at the bottom of the
> file contains copy-pasteable checks. **Run those checks.** In particular the
> second one, which inserts a chunk and confirms `search_doc_chunks` returns it
> with a score above zero — that exercises the FTS column, the trigram
> extension, the function and the grant in one go.

It creates `doc_library`, `doc_chunks`, `doc_questions`, the
`search_doc_chunks(bigint, text, int)` function, RLS policies, and the
`doc-library` storage bucket.

Two things about it worth knowing:

- **It does not touch `knowledge_docs`.** Ad-hoc uploads must not silently become
  plant-wide safety doctrine — an unreviewed contractor method statement would
  otherwise start shaping every hazard assessment. Promotion is a separate,
  explicit admin act (`promoted_doc_group`).
- **RLS is `using (true)`**, matching `ai_runs` / `knowledge_docs` and gated by
  the app's own login rather than Supabase Auth. That means anyone holding the
  publishable key can read every uploaded document. Consistent with the rest of
  the project, but a real consideration here because users upload arbitrary
  files. The header comment in the migration spells out the change if you need
  per-user reads.

## Step 3 — Install the Apps Script handler

In the **"Nara Router" proxy project** (the one whose URL lives in
`NaraVision.defaultProxyUrl`, *not* the sync backend):

1. Add `DocQaProxy.gs` to the project.
2. Confirm `Main.gs` contains the dispatch line — it does already in this repo:
   ```javascript
   if (action === 'answerFromDocument') return handleAnswerFromDocument_(data);
   ```
   If you add `DocQaProxy.gs` and forget the line you get "Unknown action". If
   you add the line and forget the file you get a `ReferenceError` reported as a
   generic error, which is harder to diagnose — so do both or neither.
3. Project Settings → Script Properties → set `GEMINI_API_KEY`
   (`GOOGLE_AI_KEY` is accepted as a fallback).
4. Deploy → **Manage deployments → edit the existing deployment → new version.**
   Updating in place keeps the URL stable, so no Flutter rebuild is needed. If
   you create a *new* deployment instead, the compiled-in
   `NaraVision.defaultProxyUrl` goes stale and every device needs the admin
   override pasted in by hand.
   Execute as: **Me**. Who has access: **Anyone** — required, because Flutter Web
   is unauthenticated from Google's point of view. Anything stricter returns an
   HTML login page, which the client reports as "returned a web page instead of
   an answer".
5. Run `testDocQa_()` from the editor. It checks three things: the key is set, a
   grounded question is answered, and — the important one — an **ungrounded
   question is refused** rather than answered from general knowledge. If that
   third check fails, the grounding prompt has regressed and the feature is not
   safe to ship.

## Step 4 — Point the app at the OCR service

Either compile the URL in:

```bash
flutter build web --release \
  --dart-define=DOC_OCR_URL=https://yourname-safetylens-ocr.hf.space
```

…or leave it blank and set it at runtime with
`DocOcrService.setServiceUrl(url)`. An unconfigured build fails with a clear
"not configured" message rather than timing out against a placeholder host,
which is why there is no default value.

If you set `OCR_API_TOKEN` on the service, pass it too
(`--dart-define=DOC_OCR_TOKEN=…`).

---

## Using it

Home → quick actions → **Ask a Document**. It is a pushed screen, not a seventh
bottom-nav tab: the nav bar is already at six tabs with 9px labels and about 3px
of clearance around the selected pill at 320px, so a seventh entry would overflow
it.

Upload, wait for the read, then ask. Documents you have uploaded before are
listed so you never pay for OCR twice.

## What to expect, honestly

- **A digital PDF is fast** — seconds. There is no OCR; the text layer is exact.
- **A scanned or photographed document is slow** — minutes, on a free CPU tier,
  one page at a time. The screen says so rather than showing a bare spinner.
- **OCR text is labelled unverified.** Below 0.80 mean confidence the screen
  warns before you act on a quoted figure. A misread digit in "isolate breaker 4"
  is exactly the error that hurts someone, and you are the only one who can catch
  it.
- **The model will refuse questions the document does not cover.** That is the
  feature working, not failing. A confident invented answer about an isolation
  procedure is more dangerous than "the document does not say".
- **If the AI is unreachable you still get the relevant clauses verbatim**,
  clearly labelled as raw document text rather than an answer.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| "The OCR service URL is not configured" | Step 4 not done |
| "returned a web page, not the OCR service" | Space is sleeping or still building; wait a minute |
| Extraction fails only in the browser, works elsewhere | CORS — add your domain to `ALLOWED_ORIGINS` |
| "run migration_doc_qa.sql" in a logged error | Step 2 not done, or PostgREST is still serving a cached schema — the migration's `notify pgrst` handles it, but give it a minute |
| Every question answers "I could not find anything" | Chunks were not written. Check `select count(*) from doc_chunks;` |
| "returned a web page instead of an answer" | Apps Script deployment access is not "Anyone" |
| "reached its free daily limit" | Gemini free-tier quota spent; it resets daily |
| Answers arrive but cite nothing | The model returned no `sources`; the screen falls back to showing the top retrieved extracts, so the answer is still checkable |

## Verification status

| Piece | Status |
| --- | --- |
| `ocr_service/` (Python) | **Verified** — 18/18 tests pass, including real PaddleOCR on a generated image (0.95 confidence) |
| `migration_doc_qa.sql` | **Not verified** — no Postgres available in the build sandbox. Run the `VERIFY` block after applying it. |
| `DocQaProxy.gs` | **Not verified** — needs a live Gemini key. Run `testDocQa_()` after installing. |
| Dart services and screen | **Reviewed, not compiled.** Two independent line-by-line passes against the real declarations of `UniversalAppBar`, `GlassCard`, `SL`/`SLText` and the two services found no compile errors, and eight runtime/logic bugs that are now fixed (listed below). But no Flutter toolchain exists in the build sandbox, so `flutter analyze` has **not** been run and the app has never been built with this code. Run `flutter analyze` before shipping. |

Bugs found by review and fixed, in case any of them look like something you would
rather have back:

- **No way off the screen.** `UniversalAppBar` draws no leading button (its tabs
  have nowhere to go back to) and the SAIL badge no-ops when the shell is
  already on Home. On Flutter Web there is no system back gesture, so the user
  was stranded. `UniversalAppBar` gained an optional `onBack`.
- **The "Answer in" chip was changing the OCR model.** `hi` selects PaddleOCR's
  Devanagari recogniser, so picking Hindi to get a Hindi *answer* would have
  OCR'd an English SOP with the wrong model and returned garbage. Ingest is now
  pinned to `en`; the chip only steers Gemini.
- **An in-flight answer could land in the wrong transcript** if the document was
  swapped mid-question — an answer with no question above it, sourced from a
  different document. "Change" is now disabled while a question is in flight,
  with an identity check behind it.
- **Ratings claimed success unconditionally.** `rateAnswer` swallowed every error
  and the question row is written without awaiting, so a fast rating could
  update zero rows and still show "thanks, noted". It now returns whether a row
  changed, and the thumbs re-enable if it did not.
- **The library was not scoped to the uploader**, so every user saw — and could
  delete — every file anyone had uploaded. Now filtered by `created_by`, with an
  empty library rather than everything when there is no signed-in identity.
- Three smaller ones: a `BoxDecoration` that combined a `borderRadius` with a
  non-uniform border (throws on every paint in a debug build), the
  "Not saved to the server" banner firing on a stale `error_message` from a
  document that *was* saved, and a language row that overflowed at larger text
  scales.
