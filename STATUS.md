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

**Observer's scene note on the AI Hazard Scan — added 2026-08-19, uncompiled.**
An optional text/dictation box on the capture screen ("What is in the picture?")
lets the observer describe the backdrop — rooftop vs floor slab, oxygen vs
nitrogen cylinder, live vs isolated line. Each of those is a distinction a vision
model routinely gets wrong and each changes the hazard class outright, so the
human hint is worth more here than any further prompt tuning.

* **It is context, never evidence.** The prompt block states that a hazard
  mentioned in the note but not VISIBLE must not be reported (it may go in
  `recommendations` instead), that `visual evidence` must describe pixels and
  never quote the note, and that the image wins any contradiction. Without those
  rules the note would satisfy the model's own "cite visible proof" requirement
  in words, and the report would invent hazards from the sentence. A false hazard
  in a safety report is not a harmless extra — it gets assigned and argued about.
* **The note is treated as data, not instructions.** It reaches the model in the
  same channel as the prompt, so `normaliseSceneContext` collapses all newlines,
  strips `` ` ``, `═`, `─`, `{` and `}` (the prompt's own fence and placeholder
  characters), caps at 400 chars, and returns empty for punctuation-only input so
  that "type a full stop to get past it" behaves like leaving it blank. The block
  also tells the model to ignore any instruction inside the quoted text, and
  `{{SCENE_CONTEXT}}` is substituted **last** so nothing typed can be read as a
  placeholder token.
* **Placement is load-bearing**, the same lesson the KB block taught: the block
  sits AFTER the anti-hallucination rules and OUTSIDE the citable regulation
  table. Inside the table it would read as a regulation; below the "never invent
  citations" line it would read as non-citable.
* **The consistency cache is now keyed on image + note** (`_resultCacheKey`).
  This was the trap: keyed on the image alone, a user who saw the AI call a roof
  a floor, added "this is a rooftop" and re-scanned would be served the very
  contextless answer they were correcting, and the note would look broken. With
  no note the key is byte-identical to before, so the 60 cached analyses survive.
* One block builder, `GeminiVision.sceneContextBlock`, is shared by both prompt
  builders. `gemini_direct_vision.dart` now imports `gemini_vision.dart` for it —
  a mutual import, which Dart allows and which `nara_vision.dart` already relies
  on. That file previously drifted into a third divergent copy of the KB block;
  safety-critical wording gets exactly one home.
* `sceneContext` defaults to `''` at every hop, so `near_miss_tab.dart` compiles
  untouched and behaves exactly as before. Contrast audit unchanged at **245
  failures / 242 warnings** — the hint line is 11px, deliberately above the 10px
  warn floor.
* Not persisted with the incident record: it shapes the analysis and is not
  currently saved. Worth revisiting — a reviewer reading the report later cannot
  see what the observer said the scene was.

**WSA-13 classification fixed 2026-09-02 — NOT yet compiled by anything.** Two
defects meant the admin panel's "WSA-13 Pareto — Root Causes" chart was measuring
artefacts rather than judgements.

* **`_wsaCause` no longer defaults to `'5. Equipment failure'`.** Every reporter
  who never opened that dropdown was filing an equipment failure, and this field
  is charted as the root-cause Pareto — so the default was steering where safety
  effort goes. It is now `''` (the sentinel the master-list reconciliation already
  used) and `_submit` refuses to file without an explicit choice.
* **Three writers were emitting values that are not WSA-13 members**, which the
  analytics screens re-attached by fuzzy keyword matching — so the stored and the
  charted classification were different values. `_mapToWsaCause` returned seven
  off-list labels, `_applyHardenedV15Filters` returned `'Equipment failure'`
  (off-list only for want of the `'5. '` prefix), and the text path assigned raw
  model output. All three now route through a new `_canonicalWsa()` resolver:
  exact match, then leading number, then label text with the number stripped,
  else `''`.
* **`_mapToWsaCause` now maps only housekeeping and returns `''` otherwise, and
  that is deliberate.** A hazard TYPE is not a CAUSE — "fall from height" does not
  say whether the cause was a missing procedure, absent supervision or a failed
  anchor point. Guessing costs nothing visible and silently becomes the Pareto.
  This trades one dropdown tap for a distribution that means something; if
  adoption suffers, argue about the tap rather than restoring the guessing.
* **`_buildDropdownField` gained a `requireChoice` flag, and it is load-bearing.**
  It did `value: items.contains(value) ? value : items.first`, so blanking the
  default would have *displayed* '1. Failure to follow procedure' while state held
  `''` — a form that looks complete submitting blank. With the flag it renders
  `value: null` and a "Select…" hint. Note the same latent bug still affects
  plant and department if an admin deletes a currently-selected master value.
* In `ai_scan_tab.dart` only the `'Multiple causes'` fallback was changed to `''`.
  The hazard-level `wsaCause` there is **still a free-text controller**, so typos
  and invented model strings can still reach `wsaCategory`. Constraining it to a
  dropdown is the real fix and has not been done; `HazardValidator` penalises an
  off-list value in the confidence score but does not correct it.

A broader occupational-safety review was done the same day and is not yet actioned.
The headline items: `rootCause` is dead schema (mapped column, i18n strings, zero
widget references); corrective actions are pipe-joined into one string so they
carry no owner, due date, completion record or effectiveness check; `VERIFIED` has
no timestamp, verifier or evidence behind it; one person can report, investigate,
close and "verify" the same near-miss because `PlantScope.canActOn` is the only
gate; the hierarchy of control appears nowhere in the scan pipeline (it exists only
in `local_ai.dart`, which feeds the chatbot); there is no actual-vs-potential
severity; `SyncStatusBar` is fully built and mounted on no screen; and the
near-miss form has one `I18n.t` call against 37 hardcoded English strings even
though the Hindi keys exist and are complete.

Two items from that review are wrong in a way worth fixing early. The
**"LTI-Free" KPI** (`overview_tab.dart:425`) is computed from
`severity == 'CRITICAL'` on any record, so rating a near-miss CRITICAL for its
potential resets the lost-time-injury counter as though someone had been injured,
and it falls back to a hardcoded `365`. And the **"Statutory Checklist — FA 1948 &
IS 14489"** (`admin_screen.dart:7220`) is ten hardcoded rows with three hardcoded
to display compliant regardless of data — a compliance panel that always says
compliant is worse than no panel.

**Near-miss form, 2026-09-02 late (commit `7c93a3c`) — NOT yet compiled.** The
same no-fabricated-defaults argument as above, applied to the reporter's own
form. `_obsType` lost its `'Unsafe Condition'` default and `''` is refused by
`_submit`; the text providers' `category` answer, which was parsed into
`_aiSuggestion` and then never read, is now applied through a new
`_canonicalObsType()`; `AdminMasterData.obsTypeGuidance()` and a matching block
in `apps_script_v14.js`'s `getSailPrompt` define act-vs-condition-vs-near-miss
for the model, where both prompts previously passed only the list of type names.
**Those two definitions are duplicated and must be kept in step.** Also: Save no
longer replaces the action row, so the PDF of a just-filed report is still
reachable (`_savedReporterName` / `_savedReporterPno` / `_postSaveBusy` hold the
persisted record); five `_err*` fields give inline validation instead of
snackbars; and `_locSource` is recorded at each fill site rather than inferred
from whether the location string contains a comma.

`Line of Fire` is deliberately **not** mapped onto act-or-condition by
`_canonicalObsType`, and containment matching is accepted only when exactly one
type matches — a bare `'Unsafe'` is a prefix of both `Unsafe Act` and `Unsafe
Condition`, and picking whichever the admin listed first would put a coin flip in
the record while the badge presents it as the AI's considered answer.

**The text analysis no longer refuses reports — 2026-09-03, uncompiled.** The
card was a gate: the model was asked `isNearMiss`, and on `false` the reporter got
a red "Does NOT Qualify as Near Miss" panel with a "Try Again" button, because
`refined`, `correctiveAction` and the accept button were all rendered only
`if (isNearMiss)`. Observed live on safetylens.in: "one person was walking and
there was a slippery surface" — a textbook unsafe condition — was refused at 95%
confidence, on a screen titled *Near Miss / Unsafe Condition*. The likeliest
result of asking a shop-floor worker to reword until the app accepts it is no
report at all.

* **Both text prompts now classify instead of judging.** `isNearMiss` is replaced
  by `hasHazard`, which is false only for text with no safety content at all
  (empty, unintelligible, a maintenance request) — explicitly *not* for "this is
  not a near miss". The JSON gained `wsaCause` and `severity`, each constrained
  to the admin's own list, and the prompt states that severity means the
  potential consequence. Changed in **two places that must stay in step**:
  `near_miss_tab.dart`'s inline prompt and `GroqService.classifyNearMiss`.
* **`hasHazard` absent is read as true.** An older cached response, or a model
  that drops the field, must not re-gate the card by default.
* **Every AI-supplied value goes through the resolver for its own field**, so an
  off-list answer becomes `''` and leaves the field alone: `_canonicalObsType`,
  `_canonicalWsa` (the Pareto field — an invented value there would be *counted*),
  and plain `_severities.contains` after upper-casing. The card resolves them
  before rendering, so it can only advertise fills that will actually land.
* **Three choices, not two: Use AI Version / Edit It / Keep Mine.** "Edit It"
  applies the text and puts the caret at the end of the description — caret, not
  select-all, because the common case is one wrong clause and a select-all means
  the first keystroke destroys what they just accepted.
* Each AI-filled field carries the `_aiSetBadge` chip via a `*FromAi` flag
  (`_obsTypeFromAi`, `_wsaFromAi`, `_severityFromAi`, `_actionFromAi`), cleared by
  that field's own `onChanged`. A stale badge would attribute the reporter's
  judgement to the model, which is exactly backwards from the point of the badge.
  The vision path sets the same flags. A corrective action the reporter has
  already typed is still never overwritten.
* **`_aiOriginalSuggestion` is now snapshotted *after* the fields are applied.**
  It records `_severity`, so snapshotting first stored the pre-AI value and made
  every later comparison read as a reporter edit that never happened.
* The card is **amber, not green or red**. Green read as "your report passed",
  which invites treating the model as the authority on someone else's own
  observation; red read as rejection. It is information awaiting a decision.

**Two form-usability fixes the same day, uncompiled.** Failed validation now
scrolls the first offending field into view (`_scrollToFirstError`, posted to the
next frame because the `errorText` rows do not exist yet in the setState that
sets them, and ordered by visual position rather than validation order). Before
this the inline errors had the same blind spot as the snackbars they replaced —
the Save button is at the bottom and the empty field is often two screens up.

And `_detailsSection`, a single 180-line card holding everything from Plant/Unit
to the last corrective action, is **split into step 2 (Observation Particulars)
and step 3 (What Happened & Action Taken)**, with a new `_stepCard()` wrapper
that tints whichever card holds focus. The split is what makes the tint mean
anything — highlighting the old card lit up almost the entire form. The
highlight is driven by descendant focus through a single `Focus` per card
(`canRequestFocus: false`, `skipTraversal: true`, or the card becomes a tab stop
between every field), and it only ever claims or releases **its own** step:
Flutter reports focus loss after focus gain, so an unconditional reset on loss
would leave nothing highlighted when moving between cards. The tint is a fill and
a border, never a text colour — `audit_contrast.py` is unmoved at **167 failures
/ 262 warnings**, verified against a baseline of the same commit.

Verified with `dart analyze` against a `git archive HEAD` baseline (see the
verification-limits section): the only new diagnostics name Flutter framework
symbols that are unresolvable in the sandbox regardless (`Widget`, `SizedBox`,
`GlobalKey`, `Icons`, `setState`), and **no diagnostic names any symbol the change
introduced**. No argument-type, duplicate-definition or assignment errors. Still
no real compile.

**Eight defects found by review of the above and fixed the same day, also
uncompiled.** Written down because most of them are the kind that fail silently
on a device rather than at the compiler:

* `_scrollToFirstError` listed the two dropdowns before `_keyLocation`, but
  Location sits **above** them on screen. On a blank-form submit — where all five
  errors fire at once, the common case — it scrolled to WSA and left the location
  error off-screen above it. That is the exact blind spot the function exists to
  close, so the ordering is load-bearing: it must match `_detailsSection`'s
  visual order, not the validation order.
* Both new prompts asked for `"refined"` as *"professional safety **English**"*
  while the same line and the `langInstruction` above it said to answer in the
  worker's language and not translate. For Hindi dictation the model was as
  likely to return English, which then lands in `_description` verbatim. The word
  is now "language" in both files. **Keep them in step.**
* The photo path set `_severityFromAi = true` unconditionally, so an off-list
  severity got an "AI" chip — and worse, assigned `sev` raw, which the dropdown
  then displayed as `items.first`: the reporter saw one value and the record
  carried another. Severity is now membership-checked there too, the badge is
  claimed only when a value landed, and `_aiOriginalSuggestion['severity']`
  records the value **applied** rather than the raw answer. The same path fills
  corrective action 1 and never badged it; it does now.
* `_loadMasterData` blanks `_wsaCause`/`_severity`/`_obsType` when an admin edits
  a master list, and it is wired to `AdminMasterData.revision` so it can run
  mid-form. It left the `*FromAi` flags set, leaving an "AI" chip on an empty
  dropdown or on a fallback value the AI never proposed. Each blanking now clears
  its own flag.
* Writing `controller.text` in code does not fire `onChanged`, so the mic and
  `_refineFieldWithAI` skipped the badge- and error-clearing that lives there: a
  reporter could dictate over the AI's corrective action and keep the "AI" chip on
  their own words. New `_noteProgrammaticWrite(controller)` is called from every
  programmatic write. **Call it from any new one.**
* `_acceptAiRefinement` gated *everything* on `refined.isNotEmpty`, so a model
  that classified the observation but returned no rewording silently dropped all
  four fields the card had already promised under "Accepting will also set:".
  Text and classification are now applied independently, the buttons show
  whenever there is anything to apply, and they relabel to "Apply Fields" /
  "Apply & Edit" when there is no wording on offer.
* "Edit It" puts the caret in the description immediately after accepting, so the
  first keystroke re-ran the classifier **on the AI's own prose**. `_acceptedAiText`
  plus `_stillSubstantiallyAiText()` suppress re-analysis while ≥70% of the
  accepted text survives at head and tail (what fixing one clause leaves behind),
  and clear once the reporter has genuinely rewritten it. The vision path sets the
  same guard, since its description is AI-written too.
* `hasHazard` was tested as `!= false`, which read the JSON **string** `"false"`
  as a hazard; and `_resetForm` did not clear `_aiSuggestion` /
  `_aiOriginalSuggestion` / `_aiOriginalSource`, so the next report opened with
  the previous one's AI reading on screen. Both fixed.

Contrast audit unmoved at **167 failures / 262 warnings** after all of it.

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

**DONE — verified live 2026-09-02.** `POST /rest/v1/rpc/get_visitor_stats` returns
HTTP 200 with real data (61 unique visitors, 13 unique employees, 3 today, 335
total visits). Nothing further is needed. The security model also verified good:
a direct `app_visitors` select with the anon key returns `200` with `[]`, so
aggregates are readable and rows are not enumerable.

The cards render in the web panel's **Users tab** (last two of the top stat row)
and in the in-app admin screen's `_moduleOverview` KPI grid. They show `—` rather
than `0` when the read fails, so `—` now means a client-side problem (stale
cached `index.html`, blocked network, or an app build predating 2026-08-14) and
not a missing migration.

Re-verify at any time with `select public.get_visitor_stats();`.

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

**Re-measured 2026-09-02: 167 failures / 254 warnings.** The numbers quoted
throughout the sections above (244/236, 245/235, 245/242) are all stale — re-run
`python3 tools/audit_contrast.py` rather than quoting any figure in this file. The
audit also now reports a colour-token section: `accentGlow`, `purple` and `red`
fail contrast as text in **both** themes, so any text painted in those literal
tokens is sub-AA everywhere. `admin_screen.dart` holds 136 of the 254 warnings.

The bare `AppColors` status tokens are left deliberately failing as text so the
audit keeps flagging any reintroduction. They are correct as **fills**.

Also deliberate, added 2026-08-19: the bottom-nav label in `home_screen.dart` is
**9px**, below the 10px floor, so the audit reports it as a failure (one line,
covering all six labels). Six tabs give each ~53px on a 320px screen and
"SOP Scan" does not fit at 10px. If it reads too small on the shop floor the fix
is to shorten that one label to "SOP" and put all six back to 10px — not to
shrink further. This moved the audit from 244 failures / 236 warnings to
**245 / 235**: the same line, reclassified from warning to failure.

## 2026-09-03 — AI text route simplified, console errors, AI card recoloured

Uncommitted and uncompiled, on top of the same day's near-miss card rework.
Prompted by a browser console screenshot from safetylens.in showing five error
classes, and by "make the AI analysing route simpler".

**The route had three hops and the third was a strictly worse copy of the
second.** `_callAiTextFallback` in `near_miss_tab.dart` re-posted the same
`{action:'gemini'}` body, with the same `text/plain;charset=utf-8` content type,
to the same Apps Script deployment `SyncService.callAiText` had just failed on —
except it pinned the deployment URL as a compile-time constant and so ignored the
`sync_backend_url` prefs override. It could therefore never succeed where the
call before it had failed; it only added a second 30s timeout. Deleted, along
with both `if (body == null)` retries, the `viaDirectFallback` locals and the
`'apps_script_direct'` telemetry provider string (no consumer anywhere in `lib/`).
`package:http` is no longer imported by that screen at all — a comment in the
import block says why it must not come back: every network hop belongs in a
service, which is where the URL override lives.

That accounts for two of the five console errors — the CORS/`ERR_FAILED` pair and
the 30s `TimeoutException`. Note a correction to an earlier diagnosis: Dart web's
`BrowserClient` surfaces a CORS rejection as an immediate `ClientException`, not a
hang, so the 30s wait was the *second* attempt, not the blocked one. Removing the
duplicate hop is what removes the wait; there was never a CORS fix to make.

**One prompt, one definition.** New `lib/services/near_miss_prompt.dart`. The
classification prompt existed in three hand-synchronised copies — a ~50-line
inline string in `_refineWithAI`, a near-duplicate in
`GroqService.classifyNearMiss`, and `getSailPrompt` in `apps_script_v14.js` — and
they had already drifted: one hardcoded five observation categories the app's own
dropdown does not offer, one still said "English" in the `"refined"` description
and so quietly regressed the Hindi path. Both Dart callers now build from
`NearMissPrompt.build` (master lists passed in) or `buildFromMasterData` (lists
fetched, each falling back to its shipped default rather than to an empty list,
because an empty list silently *removes* the constraint). The Apps Script copy
cannot import Dart and stays separate — keep its `HOW TO CHOOSE "type"` block in
step with `AdminMasterData.obsTypeGuidance`.

**Groq 404 `model_not_found`.** `availableModels` still offered `gemma2-9b-it` and
`mixtral-8x7b-32768`, both decommissioned, so an admin could pick a model that
could only ever 404 — and `complete()` returned `null` on any non-200 without
logging status or body, which is how a fleet-wide failure looked like a slow
backend. Now: those two removed, a `_retiredModels` migration map that `getModel()`
rewrites *and persists* through (changing `defaultModel` alone never reaches a
device that already saved a dead ID), `_logHttpFailure` decoding Groq's `error`
object and naming the model, an `isSupportedModel` predicate, and the same clamp
`admin_screen.dart` already applied to the Gemini and Nara dropdown seeds now
applied to the Groq one at `_loadGroqConfig`. That clamp also closes a crash:
`DropdownButtonFormField` asserts on a `value` absent from its items, so shrinking
`availableModels` with a retired ID still in prefs would have thrown.
**Anything removed from `availableModels` must be added to `_retiredModels` in the
same edit.** Still open, pre-existing: the adjacent `value: _groqVisionModel`
against `GeminiVision.groqVisionModels` is the one dropdown of this shape with no
clamp.

**`LOW: 0`.** A real data-corrupting bug, and the interesting part is how it
passed three guards. `_isOutOfRangeScale` judges the TOP of the scale, which was a
healthy 90 — one broken level does not move it. `_normaliseScale` deliberately
leaves `<= 0` alone as a "does not count", which is right for a level an admin
invented and wrong for the canonical four, where LOW is still a hazard. And
`_withCanonicalLevels` only tested whether the KEY was absent, which it was not.
The likeliest origin is the parse itself: every read does
`int.tryParse(v.toString()) ?? 0`, so an empty or non-numeric backend cell becomes
0 rather than an absent key. Now repaired in four places — `_withCanonicalLevels`
(non-positive canonical values restored, logged separately from missing ones),
`scoreFromMap` (`> 0` rather than `!= null`, returning the built-in directly so the
"NO ENTRY" message does not misreport an absent key), the master-data import
(pushed back, or the broken row is re-imported by every device forever), and
`saveSeverityScores`. A stored 0 rendered "0 / 100" on a LOW report and pulled the
plant average down as though it were a hazard-free record.

Two follow-ups from review of the above, both worth keeping in mind:

* The import path originally pushed inside *each* repair branch. `_pushWithRetry`
  is fire-and-forget, so a scale needing both repairs — `{CRITICAL:25, HIGH:15,
  MEDIUM:10, LOW:0}` is out of range AND zeroed, and is not `_isLegacyScale`
  because LOW is 0 not 5 — fired two concurrent pushes with different payloads in
  undefined order, and a failed first push is queued and replayed later,
  re-poisoning the backend after the repair succeeded. Both repairs now apply
  before a single push.
* `saveSeverityScores` repairing its input meant the admin panel's `_adjustScore`
  produced three different numbers from one tap: the tile kept showing 0, the
  audit entry recorded 0, and 20 was stored and pushed. Fixed at the source —
  `_adjustScore` now clamps to `AdminMasterData.severityBands`, which is already
  the invariant every display path enforces (`scoreForDisplay` silently lifts or
  caps a score contradicting its label), so the panel was previously offering a
  setting the app would overrule. A tap at the end of the band now toasts instead
  of appearing dead. `saveSeverityScores` also returns the map it actually stored,
  so a future caller holding state can adopt it.

**The AI card is indigo, not amber.** Amber avoided the two traps green and red
fell into — green read as "your report passed", inviting the reporter to treat the
AI as the authority on their own observation, red read as rejection — but it
collided with the app's own meaning for amber, MEDIUM severity, two fields above a
severity dropdown using the same hue for something else. `AppColors.accent` is the
primary and carries no safety meaning, and it matches the ✨ AI badge that marks
the fields this card fills, so one colour now means one thing across the whole
interaction. The no-hazard path stays red. Fill chips are tinted by the meaning of
the field each fills: indigo for the classification, cyan for the WSA-13 cause,
the severity's own signage colour for severity, green for the corrective action.

Three contrast findings from this, none of which `tools/audit_contrast.py` can
catch, because it scores tokens against the two global backgrounds and not against
a local card fill:

* The dark chip tint had to come down from 0.16 to 0.10. The tint lightens the
  fill and the cyan WSA chip is the weakest of the five foregrounds: 4.16:1 at
  0.16, 4.58:1 at 0.10. Raising it means re-measuring that chip specifically.
* The confidence badge takes a near-white fill in light mode now. The card fill
  moved from amber-cream `#FFF8E1` to lavender `#EEF0FF`, which is darker, and the
  same 15% wash took `greenText`/`redText` from 4.52/4.55:1 to 4.27:1.
* Chips keep a near-white fill in light mode rather than the card's lavender,
  because `amberLight` measures 4.43:1 on lavender and 5.02:1 on white.

An unrecognised severity label now falls back to indigo, not green. Severity
levels are admin-editable and only checked for list membership, so a plant that
renames HIGH to "SEVERE" would have got a green chip reading "Severity: SEVERE" —
the exact self-contradiction the chip colouring exists to prevent.

**Not from this app:** the `VideoFrame` console warnings. Zero matches for
`VideoFrame`, `getUserMedia` or `MediaStream` anywhere in the repo, no
camera/scanner/webrtc plugin in `pubspec.yaml`, and `image_picker_for_web` uses a
hidden file input that never opens a MediaStream. Almost certainly a browser
extension; confirm in an extensions-off incognito window. There is no app fix.

Verified: analyzer baseline diff clean — the only new `code|message` pairs name
Flutter framework symbols (`FocusNode`, `GlobalKey`, `Color`, `AnimatedContainer`,
`Flexible`, `Focus`, `KeyedSubtree`, `ScrollController`, `Wrap`, `debugPrint`),
which are unresolvable in the sandbox and new only because the diff newly *uses*
them. No diagnostic names any symbol the change introduced. Contrast audit
unmoved at **167 failures / 262 warnings**.

**The Apps Script key exposure named here as unactioned was acted on the same
day** — see the next section. The rotation of the three keys recoverable from git
history is still owed and is not something code can do.

## 2026-09-03 — Apps Script key exposure closed at the edge (step 1 of 3)

Uncommitted and uncompiled. Scope was chosen deliberately as "close the
internet-facing hole now"; the real fix is step 3 and is not done.

**What was open.** `getMasterData` was in `publicActions` and injected all five
vendor keys from Script Properties into its reply, so an unauthenticated POST of
`{"action":"getMasterData"}` returned every key in plaintext — to a deployment URL
that is a compile-time constant in a public repository. Two more public actions
spent money with no caller anywhere in `lib/`: `diagnose` fired one paid inference
per model in `GOOGLE_MODELS` on every request, and `analyzeUrl` proxied an image
URL. `upsertUser` was a public write to the user table.

**What was done.** Keys left `getMasterData` entirely (its read path now filters
`SECRET_MASTERDATA_KEYS`; `MASTERDATA_KEYS` is untouched so the admin panel can
still *write* them) and moved to a new `getAiKeys`, which — with `gemini`, the
billable proxy — is gated on a shared `APP_SECRET` script property matched against
an `_appSecret` the app sends from `String.fromEnvironment('SL_APP_SECRET')`.
`diagnose` and `analyzeUrl` were deleted; `upsertUser` left `publicActions`.

Four things about this are easy to get wrong later:

* **`appSecretOk` fails closed.** No `APP_SECRET` property set means the gated
  actions are refused, not allowed. A fallback-to-allow version would be
  indistinguishable from having no check at all. Consequence: **set the property
  BEFORE redeploying**, or AI stops working the moment the new deployment goes
  live.
* **This gate is not a secret.** On web the value is compiled into the JavaScript
  the browser downloads, and `main.dart:65` fetches master data before `runApp`,
  so keys reach `SharedPreferences` before the login screen even paints. The gate
  moves exposure from "the entire internet" to "anyone holding the build". That is
  a real reduction and it is not a fix. `lib/services/app_secret.dart` says so in
  its own doc comment and carries a deletion date.
* **Moving an action out of `publicActions` does not authenticate it — it
  disables it.** The token gate behind that list has never once succeeded in
  production: sessions are only written by `createSession`, called only from the
  Apps Script `login` action, which `AuthService.signIn` never reaches; the client
  carries a device-generated token from `_issueLocalToken`; and `createSession`
  stores `username` while the client sends `pno`. The only gated action the live
  app reaches is `saveMasterData`, from three admin helpers that send no auth
  fields and swallow the reply with `catch (_) {}` — which is why nobody noticed.
  Do not "tidy" a working action out of that list.
* **`collectAiKeys` also returns `geminiModel` and `naraModel`.** Those two are
  not secrets, but they are absent from the Supabase `master_data` mapping and the
  masterdata sheet is their only source. Switching the key fetch from
  `getMasterData` to `getAiKeys` without carrying them would have silently sent
  every device to `NaraVision.defaultModel`, the costliest option, with no error
  anywhere.

**Two files had to be rerouted to make the gate possible at all.**
`chat_tab.dart` and `pdf_kb_extractor_web.dart` each called `action:'gemini'` with
a raw `http.post` to their own pinned copy of the deployment URL, so neither could
attach `_appSecret`; both now go through `SyncService.callAiText`. A side effect
worth knowing: `chat_tab`'s raw post never UTF-8 decoded the body, so Hindi
answers were being mangled. `_appSecret` is attached in `_postWithRedirect` for
**every** request rather than per call site, because per-call-site auth decisions
are exactly how those three `saveMasterData` helpers ended up sending nothing.
Pinned URLs still exist in `drive_sync.dart`, `network_checker.dart`,
`nara_vision.dart` and `admin_screen.dart`, but they only use ungated actions
(`uploadPdfToDrive`, `analyzeImageNara`, `health`), so they keep working.

**Why the keys cannot simply be withheld from the client.** Nine paths call
vendor APIs straight from the device with a key out of `SharedPreferences` —
`groq_service.dart`, `gemini_vision.dart`, `gemini_direct_vision.dart` (key in the
query string), `nara_vision.dart` on mobile, four paths in `sop_ocr_service.dart`,
and `ai_audit_service.dart`. Only `doc_qa_service.dart` does it correctly, through
`DocQaProxy.gs`. Until those nine are proxied, gating alone would kill AI app-wide.
That is step 3, and it is the only step that actually closes this.

**Manual steps only a human can do, in this order.** Set the `APP_SECRET` script
property; add `SL_APP_SECRET` as a repository secret with the same value; **then
redeploy the Apps Script** (saving the editor changes does nothing — the `/exec`
URL serves the last *deployment*); then rotate all five vendor keys, since
anything issued before today should be assumed public. A Gemini key and two
OpenRouter keys are recoverable from git history and must be revoked, not just
replaced. Worth doing while in the consoles: set a spend cap per vendor and an
HTTP-referrer restriction on the Gemini key. Rotating `APP_SECRET` later has no
grace period — both sides change together, so redeploy and rebuild in one go.

**Found on the way, and separate: the Supabase anon key exposes every user's
`password_hash` and `salt`.** Login reads the custom `app_users` table rather than
using Supabase Auth — a deliberate choice, because the app must log in offline on
a plant floor — and the anon key is a compile-time constant in the public build.
`supabase_app_users_hardening.sql` is the fix, written but **not applied**:
sections 1 and 2 are additive and safe to run now, section 3 closes the read and
**breaks login on every device until Dart calls `verify_login`**, including any old
APK still in someone's hand. The file lists the exact Dart changes required first.
Still open after all three sections, and arguably worse than the read: the `UPDATE`
policy is `using (true)`, so anyone with the anon key can overwrite any
`password_hash`, and `INSERT` lets anyone create an `is_admin = true` account.
Neither is fixable by policy alone — the app has no server-verifiable identity.

Also still unauthenticated, unchanged by this pass and documented rather than
fixed: `addIncident`, `updateIncident`, `updateIncidentStatus`, `listIncidents`,
`addKnowledge`, `listKnowledge`, `uploadPdfToDrive` and the sheet-format actions
are open reads and writes of plant incident data.

Verified: `node --check apps_script_v14.js` passes; both workflow YAMLs parse
under PyYAML `safe_load`; analyzer baseline diff (`git archive HEAD` tree vs the
working tree) yields exactly one new `code|message` pair,
`UNDEFINED_METHOD … 'debugPrint' … type 'SyncService'`, which is sandbox noise of
the same class as the other 1457 unresolved-Flutter entries — the precedent
`import 'package:flutter/foundation.dart' show debugPrint;` is already committed at
`groq_service.dart:14`. Nothing here has been run against the live deployment.

## 2026-09-03 — model switch, and a dead primary vision model found

Uncommitted and uncompiled. Requested: drop the 404ing Groq text model, use
`openai/gpt-oss-20b` for near-miss text, and put `qwen/qwen3.6-27b` first for
hazard analysis with `minimax/minimax-m3:free` second.

**The find that matters more than the request.**
`nvidia/nemotron-nano-12b-v2-vl:free` — position 1 of the hazard chain, labelled
"fastest free image model" — **no longer exists on OpenRouter.** A check of
`/api/v1/models` (424 entries) found neither that slug nor any nemotron nano VL
variant. Every hazard scan was therefore spending its first attempt on a model
that could only fail, then quietly succeeding on the 30B fallback, which is
precisely why nobody noticed: a chain that degrades to its fallback still returns
hazards. The same slug was **the only** OCR model in `sop_ocr_service.dart`
(`_ocrModel`, no chain behind it), so SOP page scanning was failing outright, and
it also sat at position 2 of that file's `_textModels`. All three are repaired;
`apps_script_v14.js` had a stale comment recommending it that never matched the
constant underneath.

Lesson worth keeping: **verify model slugs against the provider's live listing
before tuning anything else.** The 40s Tier 1 budget and the 20s attempt timeout
were both sized from a measurement taken while position 1 was dead, so part of
what those constants were compensating for was a 404, not latency.

**Chain now:** Groq `qwen/qwen3.6-27b` → OpenRouter `minimax/minimax-m3:free` →
OpenRouter Nemotron 30B Omni → direct Gemini → Nara → offline. Both new
OpenRouter-side slugs were verified that day as `input_modalities` including
`image` at price 0.

**Groq is a new tier, not a new list entry.** `qwen/qwen3.6-27b` is served free by
Groq; the same slug on OpenRouter exists only as a **paid** model. So it needed a
real `_callGroqVision` against `api.groq.com` rather than a string added to the
existing chain — sending it down the OpenRouter path would silently bill credits.
Four things about that tier:

* **The pin is now resolved once, before Tier 0, and it selects a TIER.**
  Previously `vision_model_pinned` was read inside the OpenRouter block and could
  only mean "this OpenRouter model". A Groq pin read there would have gone to
  OpenRouter as a paid request. Two reads could disagree, so there is one.
* **A pin disables the whole fallback chain** — that was already true and is now
  dangerous, because a device pinned to the removed Nano VL would fail *every*
  scan and land on the offline fallback, which reports "no hazards found". On a
  shop floor that reads as "this scene is safe". Hence `_retiredVisionPins` and
  `_migrateRetiredVisionPin`, which clears such a pin before analysis runs rather
  than only when an admin happens to open the settings screen.
* **Tier 0 is not billed against `_kTier1Budget`.** That budget bounds how long
  we shop for a *free OpenRouter* model; Groq is a different account with a
  different allowance. It is bounded by `kAttemptTimeout`, so the worst case grew
  by one 20s attempt, not without limit.
* **Every failure in Tier 0 is swallowed.** A new first tier must not be able to
  break a chain that worked without it.
* **The key sync condition had to widen.** It fired only when no OpenRouter key
  was usable, so a device that already had one would never have synced a Groq
  key — the new "primary" would have been skipped silently forever.

**Groq text model.** `defaultModel` is `openai/gpt-oss-20b`;
`llama-3.3-70b-versatile` (now 404ing) and `llama-3.1-8b-instant` both moved into
`_retiredModels`, whose values are now all `defaultModel` rather than repeated
literals — five entries had been redirecting dead IDs *to another dead ID*.
`availableModels` is deliberately a single entry (admin decision), so understand
the consequence: if that ID is wrong there is no model to switch to from the
panel, and near-miss text falls through to the slower Apps Script path until a
rebuild. Adding a second entry is the whole fix.

**Both admin dropdowns are now clamped.** `DropdownButtonFormField` asserts when
`value` is absent from `items`, and both lists shrank in this change, so the
vision dropdown — flagged in the 2026-08 write-up as the last one of its shape
without a clamp — would have thrown on open. The `_groqVisionModel` field is
clamped too, not just the widget, because the field is what "Update Model
Selection" writes back: a widget-only clamp shows "Auto" while saving the dead
slug.

**Cannot be verified from here, and should be checked on a real scan.** Groq's
model list requires a key, so `qwen/qwen3.6-27b` and `openai/gpt-oss-20b` were
taken on trust from the admin's screenshot — both are plausible Groq IDs and
neither was confirmed. A wrong one shows up as Groq HTTP 404 `model_not_found`,
which `_callGroqVision` now logs with the provider's own message. `minimax-m3`
is also unverified as *non-reasoning*, which matters only for `_ocrModel`: if SOP
OCR starts returning truncated page text, suspect thinking tokens eating the
4096-token budget and try `google/gemma-4-31b-it:free`.

Untouched by request: Gemini, Nara and the `ai_audit_service` models. Note the
audit path's Groq default (`llama-4-scout-17b-16e`) was not checked and may be
dead too; it is overridable from the `groq_audit_model` pref without a rebuild.

Verified: analyzer baseline diff is **exactly zero** new and zero resolved
diagnostics (1582 unique `code|message` pairs either side, baseline built by
`git archive HEAD` at `a62b225` — the previous session's 1581 became 1582 because
the security work is now committed, which accounts for that entry). `node --check
apps_script_v14.js` passes. No model ID was exercised against a live provider.

## Verification limits

There is no Flutter SDK in the agent sandbox, so **no change made by an agent has
been compiled.** CI (Flutter 3.19.6) is the first real compile — avoid Dart 3
record/pattern switch expressions. Keep `.gitattributes` (`* text=auto eol=lf`);
a Windows checkout once flipped the tree to CRLF and turned a 22-file diff into
171.
