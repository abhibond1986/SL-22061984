# Safety Lens — current status

**Last verified: 2026-08-14** against the live repo and the Supabase REST API.
The SOP/SMP scan feature was added on 2026-08-19 — as a **bottom-nav tab at
index 3**, between Near Miss and Ask AI, taking the bar from five tabs to six.
Tab indices now live in `lib/utils/app_tabs.dart`; there must be no bare tab
integers anywhere, because a wrong one opens the wrong tab without failing to
compile. The feature now **compiles for both targets**: CI run #642 (web) and
#581 (release APK) both went green on commit `89967ac`, 2026-08-19 09:12Z, after
the R8 keep rules below. That covers compilation and shrinking only — no part of
the scan flow has been exercised on a device, and the Supabase migration in step 3
has not been run, so cloud sync of scanned clauses is still untested.

**Added after that green run, and therefore NOT yet compiled by anything:** the
safety-analysis pass (`lib/services/sop_safety_analysis.dart`, new) and its review
UI in `sop_scan_screen.dart`, plus Hindi/Devanagari on-device OCR. The next CI run
is the first compile of any of it. What it adds to the review screen: critical
requirements with a criticality bar and a tap-through to the quoted source line,
hazards, a pre-job checklist **split into "from the document" and "AI suggested"**,
requirements grouped by the 15 fixed categories, points-to-check, the AI
disclaimer, and a collapsed read-only view of the raw OCR text.

Three properties of that feature are load-bearing and should not be "tidied":

* **`_safety` is nullable and separate from `_extract`.** The safety read is a
  screen-only aid; the extract is what gets saved. A failed analysis must never
  block filing the document, and `_save()` deliberately knows nothing about it.
* **`SopCheckItem.fromDocument` is set once, in the service, from which JSON
  array the item arrived in.** It is never re-derived at display time. Merging
  the two checklist groups silently promotes an AI guess to a document
  requirement, which on a shop floor is the whole risk this feature carries.
* **Requirements carry `verified`**, set by matching the model's quoted
  `source_text` back against the OCR text. Unmatched ones are labelled
  UNVERIFIED in the UI rather than dropped, because a dropped requirement is
  invisible and a labelled one is checkable.

**Provider tiers in the SOP path — fixed 2026-08-19 after a live failure, also
uncompiled.** A web scan on safetylens.in timed out four times and then silently
produced a mechanical page-per-clause extract. Cause: both SOP paths (page OCR
and the text passes) stopped at OpenRouter → Nara, and **on web those are the
only two tiers that exist** — there is no ML Kit in a browser and Nara is
CORS-blocked, so one queued free model left no reader at all. The text path was
worse still: one model, a 45s timeout per key, and a `return null` on
`!NaraVision.isUsableHere` that made the code after it unreachable on web.

Four changes, all inside `lib/services/sop_ocr_service.dart`:

* **Gemini direct is now the last tier on both paths.** This is the same
  conclusion `gemini_vision.dart` already records for hazard scans — when the
  free allowance goes, every free model 429s together, so a configured Gemini
  key is the only thing left. Built locally from `GeminiDirectVision`'s existing
  public `isConfigured` / `getApiKey()` / `getModel()`; it deliberately does not
  call `analyzeImage`, which carries the hazard prompt and hazard-shaped JSON
  validation.
* **The text passes use a model chain, not `_ocrModel`.** Instruct model first
  (`google/gemma-4-26b-a4b-it:free`); both prompts want JSON, which is an
  instruct job, and the vision model was only there because it was the constant
  already in the file. The 30B reasoning model is **excluded on purpose** — it
  spends the 4096 `max_tokens` on thinking and returns truncated JSON.
* **45s → 20s per attempt, with a 40s tier budget** mirroring `_kTier1Budget`.
  The 45s was justified as "a whole document needs longer", which confuses output
  size with queue time; the measured evidence is in `gemini_vision.dart`.
* An empty HTTP 200 is now treated as a failure and moves to the next model,
  rather than being returned as `""` for the caller to parse as JSON.

Worth knowing before optimising: the scan screen calls the chain **twice in
sequence** (structuring, then safety), so a total outage costs two budgets end to
end. Parallelising them was considered and not done — two concurrent free-tier
requests risk throttling each other, which would trade a slow success for a fast
failure. The safety pass's one JSON-repair retry cannot compound this: it only
fires when a model actually replied.

The badges in that UI are 10px, not the 9px used by the nav labels. The 9px
waiver was granted for nav labels specifically; HIGH/MEDIUM/LOW is the safety
signal itself. `tools/audit_contrast.py --strict` is unchanged at **245
failures**; warnings moved 235 → 238, all three being the new 10px badges, which
the audit treats as warn-level (there are already 128 such in `admin_screen.dart`).

**The SOP Scan tab is behind an admin release flag — added 2026-08-19, also
uncompiled.** The feature still has rough edges, so it is not on general release;
the admin panel now has a **System Health → Feature Release** card holding a
`SOP Scan Tab Visibility` switch.

* **Admins always see the tab, whichever way the flag is set.** This is not an
  oversight. The flag exists so the feature can be exercised against real plant
  documents in production before release; if the flag hid the tab from admins as
  well, the only way to test would be to release it to everyone first. Everyone
  else sees the tab only when the flag is on.
* **The flag is `admin_show_sop_scan_tab`, defaulting to OFF** — note that this
  is the opposite default from `spiCardVisible`, which is on. It syncs through
  the generic `master_data` key/value table as `sop_scan_tab_visible`, so it
  needs **no schema migration**. Other devices pick a change up on their next
  sync, not instantly.
* **`AdminMasterData.sopScanTabVisibleSync` is a write-through snapshot**, and
  unlike `_wsaSnapshot` it is deliberately *not* cleared by `_bump()`. Clearing
  it would read false — hiding the tab — for the whole async gap until
  `primeSnapshots()` finished, so editing any unrelated admin setting would blink
  the tab off for every user entitled to see it.
* **`tabs` and `items` in `home_screen.dart` stay `AppTabs.count` long.** Only
  the rendered nav `Row` is filtered, via `_visibleTabs`. The indices remain
  canonical, so the nine `onTabChange(AppTabs.x)` call sites keep working
  untouched. Removing the `SopScanScreen` entry conditionally is the tempting
  version and it makes `tabs[AppTabs.reports]` throw a RangeError.
* `_changeTab` also refuses a hidden index, because it is the target of the quick
  actions and of `UniversalAppBar.onHome` — gating only the visible bar would
  leave a deep link into an unreleased feature. The home-tab quick action is
  hidden by the same test, so nobody gets a button that silently does nothing.
* Admin membership is tested with `PlantScope.isAdminUser`, never
  `u['isAdmin'] == true`: `isAdmin` is stored as a real bool when seeded and as
  the *string* `'true'`/`'false'` at registration and when toggled.
* `apps_script_v14.js`'s `MASTERDATA_KEYS` whitelist gained `sopScanTabVisible`
  — and also `spiCardVisible`, `spiParams` and `severityScores`, which were
  already being sent and **silently dropped**. Unlisted keys are discarded by
  both `saveMasterData` and `getMasterData`. Needs a redeploy to take effect, and
  only matters if the legacy backend is ever used again.
* Contrast audit after this change: **245 failures, unchanged**; warnings moved
  238 → 242, all four being the new card's 10px labels.

This file is the single place that states current reality. Every other markdown
file at the root is a point-in-time note from when a feature was built; those
describe what was true *that day*, not what is true now. Superseded notes have
been moved to `docs/archive/`.

`README.md` is included in that warning and is actively wrong: it advertises
"100% offline — no internet, no API keys, no cloud required" and a `demo`/`demo`
login, none of which holds. The app depends on Supabase, Firebase Messaging and
remote Gemini/OpenRouter calls. Do not use it to reason about the architecture.

---

## Outstanding deploy steps

These are the things that are broken or unverified right now. Nothing else in
this repo tracks them, which is why they kept getting missed.

### 1. Confirm `incidents` is in the `supabase_realtime` publication

**Still open.** Cannot be checked with the anon key — it needs the dashboard:
Supabase → Database → Replication. Without it, live cross-device updates never
fire, and nothing surfaces an error; the app just quietly stops agreeing with
itself across devices.

### 2. Run `supabase_visitors_setup.sql` (required for the visitor counter)

**Still open — one-time, takes a minute.** Supabase → SQL Editor → New query →
paste the whole file → Run. Idempotent, so re-running is safe.

Until this is run, the "Unique Visitors" and "Signed-in Staff" cards in BOTH
admin panels show `—`. They are deliberately never `0`, so "not set up" cannot be
mistaken for "nobody has used the app". Nothing else breaks: the client swallows
the missing-function error and startup is unaffected.

Verify with `select public.get_visitor_stats();` — a fresh install returns a JSON
object of zeros.

Note the security model, and don't "fix" it by adding a policy: the table has RLS
on with **no anon policies at all**, and all access goes through two
`SECURITY DEFINER` functions. That is what keeps the public anon key from being
able to enumerate who visited — it can only record its own visit and read
aggregate counts.

### 3. Run `migration_sop_scan.sql` (required for the SOP/SMP scan feature)

**Still open — one-time.** Supabase → SQL Editor → New query → paste the whole
file → Run. Idempotent.

Adds the columns the scan writes to `knowledge_docs`: `doc_group`, `sop_number`,
`clause_no`, `page_from`, `page_to`, `plant`, `uploaded_by`, `indexed`,
`verified`, plus indexes on `doc_group` and `verified`.

Until it is run the feature looks like it works and then loses everything:
PostgREST rejects the **entire row** on an unknown column (`42703`), and
`knowledge_docs` has no schema-gap guard, so every scanned clause stays on the
device that scanned it and reaches no other device. The local KB and the AI chat
work regardless — only the cloud push fails.

Verify with:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "$SUPABASE_URL/rest/v1/knowledge_docs?select=doc_group,sop_number,clause_no,verified&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
```

`200` = applied. `42703` in the body = not yet.

### 5. Self-host pdf.js if PDF import is to work on the web

**Open, and it will bite on a plant network.** PDF import (added 2026-08-19) uses
`Printing.raster` from the `printing` package. On Android and iOS that is native
and self-contained. On **web** the plugin injects a `<script>` for
`https://unpkg.com/pdfjs-dist@3.2.146/build/pdf.min.js` plus its worker on first
use — verified against `printing-5.12.0/printing/lib/printing_web.dart`, not
assumed. If that CDN is blocked, web PDF import cannot work.

It fails *visibly*: `SopDocImport.canReadPdf()` probes with a 12s timeout and the
screen names the cause. The timeout is load-bearing — a script tag that fails to
load fires `error` and never `load`, and the plugin awaits `load`, so without it
`Printing.info()` never returns and the Import button hangs forever.

The fix is to vendor `pdf.min.js` and `pdf.worker.min.js` into `web/` and set
`window.dartPdfJsBaseUrl` in `index.html` before Flutter boots; the plugin reads
that global in preference to unpkg. Same job as the font self-hosting below, and
worth doing in one pass.

Word (.docx) and .txt import have no such dependency — pure Dart via `archive`,
and their text is used exactly as stored rather than being sent through OCR.

**Release APK keep rules — added 2026-08-19, and do not delete them.**
`flutter build apk --release` failed at `:app:minifyReleaseWithR8` with missing
classes for the Chinese, Devanagari, Japanese and Korean text recognizers. The
plugin's `TextRecognizer.initialize` references all five scripts, but only the
Latin bundle is a transitive dependency, and R8 treats the dangling references as
errors in a release build. Fixed with `-dontwarn` for those four packages in
`android/app/proguard-rules.pro`, plus `-keep` on the Latin recognizer and both
plugin packages (ML Kit resolves options reflectively, so a renamed class only
fails at runtime, on the first scan, in a build that has already shipped). Debug
builds do not minify, so this failure appears only in release.

Also needs `flutter pub get` once, for the new
`google_mlkit_text_recognition: ^0.13.0` dependency. Pinned to 0.13.x
deliberately: 0.14 wants a newer Kotlin/AGP than the CI Flutter 3.19.6 toolchain
ships with. Web builds do not use it — `sop_ocr_device.dart` routes web to a stub
via conditional export, so no ML Kit or `dart:io` code reaches the web bundle.

### 4. Confirm row-level security is enforced on `incidents`

**Unverified, and worth doing deliberately.** The Supabase URL and anon key are
committed in plaintext in `lib/services/supabase_config.dart`, in a repo that has
a `CNAME` and a public Pages deploy. That is only safe if RLS is actually on and
its policies are restrictive. If RLS is off, the committed key is a public read
(and possibly write) handle on real incident data.

Check in Supabase → Authentication → Policies, or:

```sql
select relname, relrowsecurity from pg_class where relname = 'incidents';
```

### Already done — do not re-run blindly

- **`migration_workflow_fields.sql` — applied.** Verified 2026-08-14 15:32Z: all
  eight workflow columns (`investigation_started_at`, `action_taken_at`,
  `closed_by`, `closing_remarks`, `closed_at`, `assigned_to`, `assigned_at`,
  `target_date`) return `HTTP 200` from PostgREST. They returned `42703` earlier
  the same day, so this was applied in between.

  Kept here because it mattered: PostgREST rejects the **entire row** when one
  column is unknown, so before the schema-gap guard below, *every* incident
  upsert failed once a record had been closed or assigned — closure remarks and
  corrective actions stayed on the device, and the next realtime UPDATE could
  hand other devices a row without them.

  Re-verify at any time:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' \
    "$SUPABASE_URL/rest/v1/incidents?select=closed_at,closing_remarks,assigned_to,target_date&limit=1" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
  ```

  `200` = fixed. `42703` in the body = regressed.

- **Apps Script — deployed and current.** Verified 2026-08-14 15:32Z. The live
  `/exec?action=ping` reports `version: "v25"`, matching the `v25` string in
  `apps_script_v14.js`, so the `INCIDENT_COLS` header change is live. The ping
  also confirms `googleKeyPresent` and `openrouterKeyPresent` are both true with
  `primaryProvider: "google"`.

  Note the filename is historical — the file is at the **repo root** (not in
  `apps_script/`, which only holds `AlertSystem.gs`) and is named `_v14` but
  contains v25. It is the AI proxy and API keys live in its Script Properties, so
  it cannot be removed. Re-check with:

  ```bash
  curl -sL "$APPS_SCRIPT_EXEC_URL?action=ping"
  ```

- **`supabase_ai_runs_setup.sql` and `supabase_ai_corrections_setup.sql` —
  applied.** The `ai_runs` and `ai_corrections` tables exist and hold rows.

---

## Known state

- **Git:** `main` clean and fully pushed as of 2026-08-14.
- **Version:** `1.0.98+98` (also hardcoded in two Dart files — known, deliberate).
- **Backend:** Supabase for data; Google Apps Script retained as the AI proxy.
- **Schema-gap guard:** `SupabaseService.upsertIncident` now learns unknown
  columns from the PostgREST error, drops them and retries, so a future missing
  migration costs those fields instead of the whole record.
  `SupabaseService.incidentSchemaGaps` lists any it has hit — surface it in the
  admin panel rather than letting it fail silently.

## Web load performance

Addressed 2026-08-14. First paint used to be gated on three independent things,
which is why it felt so slow:

- **A 10-second blocking network call.** `main()` awaited
  `AdminMasterData.syncFromBackend()` with a 10s timeout *before* `runApp`, so a
  slow or blocked network meant up to ten seconds of blank screen. Now
  cache-first: snapshots are primed from local storage, the refresh runs
  unawaited, and the `revision` listener re-primes when it lands. The listener
  must be attached *before* the sync starts — see the comment in `main.dart`.
- **~2 MB of oversized icons on the critical path.** One 1024px, 1.03 MB PNG was
  serving as the runtime asset, the splash image, three `<link rel=icon>`s, and
  (via a CI copy step) the favicon. All four PWA icons were the same 558×447
  non-square file, so the sizes in `manifest.json` were false. Regenerate with
  `python3 tools/gen_icons.py`; CI now fails if a web icon exceeds 200 KB.
- **Engine boot waiting on `window.onload`**, which does not fire until every
  subresource has downloaded. Now boots on `DOMContentLoaded`.

Also re-enabled icon-font tree-shaking (`--no-tree-shake-icons` removed), worth
~1 MB. Audited first: `lib/` contains zero `IconData(...)` constructions and no
string→icon maps. **If anyone ever adds a dynamically-built icon, tree-shaking
renders empty boxes at runtime with no build error** — restore the flag if that
appears.

### Still worth doing: self-host the fonts

`google_fonts` fetches Inter and Poppins from `fonts.gstatic.com` at **runtime**,
on every cold load, from a plant network that may well be slow or filtered. Only
`preconnect` hints were added (a real but small win); the actual fix is to vendor
the `.ttf` files into `assets/fonts/`, declare them in `pubspec.yaml`, and use
`TextStyle(fontFamily: ...)` instead of `GoogleFonts.*`. That also makes the app
render correctly with no internet at all, which matches how it is actually used.
Not done because it touches every screen's typography and deserves its own visual
check.

## Readability / design debt

Run the audit any time:

```bash
python3 tools/audit_contrast.py          # report
python3 tools/audit_contrast.py --strict # exit 1 on failures, for CI
```

Fixed on 2026-08-14: the seven on-screen labels below 8px (6-7px badge and step
text), and `SL` gained theme-aware foreground getters — `critText`, `redText`,
`amberText`, `greenText`, `accentText`, `cyanText`, plus `textOn(fill)`. All six
pairs measure ≥5.0:1 in both themes.

Still open, both mechanical but needing a look on a real device:

- **84 sites** use a bare `AppColors.amber/red/green/accent` as a text or icon
  colour. Amber is 2.15:1 on white and green 2.54:1 — unreadable. Fix by
  switching to the `sl.*Text` getters. Two traps: the call site may be inside a
  `const` constructor (possibly an *outer* one), and `sl` must be in scope.
- **146 sites** below 10px, plus 191 at exactly 10px as warnings. Raising these is
  a one-line change each and cannot break compilation, but it can change dense
  analytics layouts, so it needs a visual pass. `admin_screen.dart` alone holds 93
  of the 10px warnings, so start there for the biggest single-file win.

Audit total as of 2026-08-14: **230 failures** (84 token + 146 type floor) and
**191 warnings**.

The bare `AppColors` status tokens are left deliberately failing as text so the
audit keeps flagging any reintroduction. They are correct as **fills**.

Also deliberate, added 2026-08-19: the bottom-nav label in `home_screen.dart` is
**9px**, below the 10px floor, so the audit reports it as a failure (one line,
covering all six labels). Six tabs give each ~53px on a 320px screen and
"SOP Scan" does not fit at 10px. If it reads too small on the shop floor the fix
is to shorten that one label to "SOP" and put all six back to 10px — not to
shrink further. This moved the audit from 244 failures / 236 warnings to
**245 / 235**: the same line, reclassified from warning to failure.

## Verification limits

There is no Flutter SDK in the agent sandbox, so **no change made by an agent has
been compiled.** CI (Flutter 3.19.6) is the first real compile — avoid Dart 3
record/pattern switch expressions. Keep `.gitattributes` (`* text=auto eol=lf`);
a Windows checkout once flipped the tree to CRLF and turned a 22-file diff into
171.
