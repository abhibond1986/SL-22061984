# SafetyLens Enterprise Readiness — Implementation Plan & Risk Assessment

**Date:** 2026-09-26
**Branch:** `hardening/enterprise-readiness` (off `main` @ `60b2bb3`)
**Scope:** the 12-workstream enterprise-readiness brief
**Status:** plan approved for Phase 1; Phases 2–4 not yet started

---

## 1. What I found before planning

I inspected the codebase rather than taking the brief at face value, because several
requested items already exist and one unrequested item is more urgent than anything
on the list. The full audit is summarised here; specifics are cited in the
security and architecture deliverables.

### The startup hang has a single identifiable cause

`lib/main.dart` awaits six calls before `runApp()`. Five are local-only and complete in
milliseconds. The sixth, `SupabaseService.init()`, wraps `await Supabase.initialize(...)`
with **no timeout and no try/catch**, and it is reached on every launch because
`SupabaseConfig._requested = true` with hardcoded credentials — the "no-op until
configured" comment above the call is stale. On a captive portal or a plant firewall
that accepts the TCP connection and never replies, that await has no application-level
deadline, so `runApp()` is never reached and the user sees "Initializing…" indefinitely.
An exception produces the same outcome.

Three things turn that single fault into an unrecoverable one:

- `lib/` contains **zero** `runZonedGuarded`, `FlutterError.onError`, `ErrorWidget.builder`
  or `PlatformDispatcher.onError`. There is no error boundary anywhere in the application.
- The HTML preloader in `web/index.html` only removes itself on success. There is no
  timeout branch, so a failed boot has no UI at all.
- `lib/screens/splash_screen.dart` adds an unconditional `Future.delayed(2000ms)` that
  dominates a healthy cold start, and its `_navigate` has no try/catch — so if the
  earlier `LocalDB.init()` failed, `getCurrentUser()` throws `LateInitializationError`
  and the spinner runs forever.

This is why startup is Phase 1A: one contained defect, disproportionate user impact,
and low regression risk to fix.

### The most serious problem is not in the brief

Supabase row-level security is `using (true)` for the `anon` role on `incidents`,
`app_users`, `knowledge_docs`, `master_data` and `device_tokens`. The anon key ships
inside the published web bundle. The practical consequences today are:

- **Every password hash and salt in `app_users` is publicly readable.** Hashing is
  `sha256(salt + password)` with no KDF and no iteration count, so those hashes are
  cheap to attack offline at scale.
- **Anyone can INSERT an `app_users` row with `is_admin = true`**, or UPDATE an existing
  row's `password_hash` — that is unauthenticated account takeover and privilege
  escalation, with no exploit skill required beyond reading the JS bundle.
- Password verification happens **client-side**, after the hash is pulled to the device.

Secondary to that, but part of the same picture: the Apps Script auth gate has never
functioned (documented in the repository's own comments — sessions are only written by
an unreachable `login` action, and the token is generated on-device, so validation can
only ever answer "Token not found"). The session token is device-generated and never
server-verified. The admin panel gate is the hardcoded string `'admin'`. `chat_tab.dart`
still grants admin from a designation substring match, so self-registering as "AGM"
is enough.

Net position: **there is no server-side authorization tied to user identity anywhere in
the system.** Roles do not exist as data — authorization is one `is_admin` boolean plus
two derived plant scopes. This is what makes RBAC (Phase 1C) a genuine build rather than
a configuration change, and why it must land with the RLS lockdown rather than before it.

### Contractor Access is broken in a specific, silent way

The login screen navigates unauthenticated into `ContractorHomeScreen`, which hands the
**full** employee `AIScanTab` and `NearMissTab` a hardcoded fake user map. But those tabs
re-read the real session for attribution, and in contractor mode there is no session.
So every contractor report is filed as `reportedBy: 'Unknown'` with a blank P.no and a
blank plant — and because a blank plant makes `PlantScope` show the record to everyone
while `canActOn` makes it actionable by no one, **contractor reports are orphaned on
arrival**. They are visible and permanently un-triageable. No one would notice from the
UI that submission succeeded.

There is also no contractor form (no company, mobile or area fields), no submission
reference number, and no status lookup. And because the route is public, unauthenticated
visitors can spend your Gemini/OpenRouter quota through AI Scan.

### Roughly half the brief already exists

To avoid rebuilding working features, these are present and should be extended rather
than replaced: the admin-configurable five-stage status ladder with forward-only
advancement, target dates and assignment; the plant-scoped assignment engine and
derived worklist; `admin_audit.dart` with 29 action codes; alert rules; the
clause-level `knowledge_docs` SOP store with verified/indexed governance and citation
formatting; ranked full-text document retrieval; four analytics tabs, seventeen admin
modules, and CSV/PDF export.

Most notably, **workstream 7's AI-advisory requirements are largely met already** and are
the most mature part of the codebase: per-hazard confidence with itemised human-readable
reasons, citation verification against a regulation catalogue and the plant knowledge
base, needs-review flagging, a review sheet with per-hazard accept/edit/delete, a
correction-feedback loop that distinguishes "AI mistake" from "user preference", and a
second-model background audit. Phase 3 refines labelling and adds the missing
never-auto-close guarantee; it does not rebuild this.

---

## 2. Decisions taken (confirmed with the product owner)

| # | Decision | Rationale |
|---|---|---|
| 1 | Work on `hardening/enterprise-readiness`; never push to `main` | Both existing workflows deploy `main` → production at safetylens.in. A feature branch is the only safe staging mechanism available. |
| 2 | Fix auth via Postgres `SECURITY DEFINER` RPC + RLS lockdown, **not** a migration to Supabase Auth | Preserves existing accounts with no forced re-registration. The `verify_login()` groundwork already exists in `supabase_app_users_hardening.sql` but was never wired up. Materially lower migration risk than replacing the identity system. |
| 3 | Contractor Access stays no-login; protect it with server-side rate limiting + CAPTCHA, and restrict AI scan for contractors | Keeps the frictionless field workflow the brief specifies, while closing the quota-abuse and bot-submission exposure. |
| 4 | Phase 1 = startup fix, landing page, RBAC | Chosen by the product owner. Note the consequence in §4. |

---

## 3. Phasing

Each phase ends at a verifiable state. I do not start the next until the current one is
green in CI.

### Phase 0 — verification scaffolding *(complete)*
Added `.github/workflows/verify.yml`: analysis, unit tests and a real release web build
on every branch except `main`/`master`, with the build uploaded as a downloadable preview
artifact and bundle size reported. No `pages: write` permission, so it cannot deploy.

This existed nowhere before. Neither shipped workflow ran `flutter analyze` or
`flutter test`, which means **the repository has had no automated verification at all**,
and the only way to discover whether a change compiled was to push to `main` — which
deploys to production. This scaffolding is also my only compile path, since the agent
sandbox has Node and Python but no Flutter/Dart toolchain.

### Phase 1A — startup performance and reliability *(workstream 1)*
Timeout-bound every blocking startup await and make each one survivable; wrap the app in
`runZonedGuarded` with `FlutterError.onError` and a branded `ErrorWidget.builder`; add an
8-second timeout branch to `web/index.html` with the specified copy, a Retry button,
connection guidance and a support reference ID; delete the fixed 2-second splash delay;
add error handling to `splash_screen._navigate`; fix the lost-update race between
`migrateInlineImages()` and `purgeStoredImages()` (both read-modify-write the same
`incidents` key unawaited); add API retry with exponential backoff; replace indefinite
spinners with skeletons; add client-side startup/error telemetry; and ensure no error
path exposes secrets, internal URLs, stack traces or schema details.

**Deferred from this workstream:** lazy loading and code splitting. Flutter Web compiles
to a single `main.dart.js`; meaningful splitting requires `deferred as` imports and a
per-feature refactor. It is real work with real regression risk, it is not what is
causing the hang, and it belongs with the bundle-size work in Phase 4. Stated here so it
is not mistaken for done.

### Phase 1B — landing page clarity *(workstream 2)*
The specified intro sentence, three feature cards and the five-step "how it works" flow,
added to the login screen within existing SAIL branding and `SL.of(context)` theming.
Built accessibly and responsively from the start (320–1440 px, semantic labels, 44 px
targets) so Phase 3's accessibility pass does not have to revisit it. Avoiding the known
`CrossAxisAlignment.stretch`-on-a-`Row` trap, which fails silently in release web builds
and blanks every sibling below it.

### Phase 1C — RBAC with server-side enforcement *(workstreams 4 and 10, partial)*
The highest-risk phase, sequenced deliberately:

1. Add a `role` column; migrate `is_admin = true` → `corporate_admin`, everyone else →
   `employee`. Keep `is_admin` in place and dual-write during transition so a rollback
   does not lock anyone out.
2. Move password verification server-side into `verify_login()`; switch the Dart auth path
   to the RPC; upgrade hashing to an iterated KDF with transparent rehash-on-login.
3. Only then close the RLS policies, table by table, verifying each against the preview
   build before moving to the next.
4. Server-side audit table for access-denied events, role changes, exports and admin
   actions. The current `admin_audit.dart` is local-only and per-device, so it cannot
   support an audit claim today.
5. Remove the hardcoded `'admin'` password gate and the `chat_tab.dart` designation
   heuristic; add approval/activation controls; ensure registration grants no privilege.

**Ordering is load-bearing.** Closing RLS before the RPC path works locks every user out
of a production system. Every step is independently revertible, and the `is_admin`
column is not dropped in this phase.

### Phase 2 — Contractor Access *(workstream 3)*
Restricted no-login route with a proper contractor form, correct attribution (fixing the
orphaned-record defect), submission reference numbers, status lookup by reference +
mobile, server-side validation, rate limiting, CAPTCHA, upload type/size validation, and
verification that the route grants no path to internal data. Depends on Phase 1C, because
"restricted" is only meaningful once enforcement is server-side.

### Phase 3 — workflow, CAPA, SOP linkage, accessibility *(workstreams 5, 7, 8, 9)*
Classification taxonomy including the BBS/SMP/SOP-violation categories that do not exist
today; a first-class corrective-action entity (today actions are free-text fields on the
incident with a single shared target date); closure evidence with the "no closure without
evidence for High/Critical" rule; reopen and escalation; SOP lifecycle fields and a
persisted observation↔clause link; the WCAG 2.2 AA pass and audit.

### Phase 4 — dashboards, Android size, trust pages *(workstreams 6, 11, 12)*
Observation-type and action-ageing dashboards; bundle and APK reduction including the
deferred code splitting, on-demand AI assets and WebP/AVIF conversion; offline-first
capture with sync status; privacy policy, terms, version and release notes, feedback.

---

## 4. Risk assessment

### Risks accepted by the chosen phasing

**R1 — Contractor Access stays broken through Phase 1.** *High likelihood, medium impact.*
Phase 1 was scoped to startup, landing and RBAC, so the orphaned-record defect persists
in the interim: contractor reports continue to file as "Unknown" with a blank plant and
remain un-triageable, and the public AI quota exposure remains open. **Mitigation:** as
part of Phase 1C I will gate the contractor route behind the new role model so it cannot
become an authentication bypass, and I will disable or throttle unauthenticated AI scan
as a one-line quota stopgap. If you would rather not wait, the attribution fix alone is
small and I can pull it into Phase 1 on request.

**R2 — RBAC is the riskiest workstream and is scheduled first.** *Medium likelihood, high
impact.* Locking down RLS touches every data call in an 80k-line codebase with no existing
test coverage of those paths. Getting the order wrong locks users out of production.
**Mitigation:** the strict five-step sequence above; dual-write and retain `is_admin`;
close policies one table at a time; every step independently revertible; nothing reaches
`main` without your approval. I will not close a policy I have not exercised against the
preview build.

### Risks inherent to the environment

**R3 — I cannot compile or run tests locally.** *Certain, medium impact.* The sandbox has
no Flutter/Dart toolchain, so every compile and test result comes from a CI round trip.
This slows iteration and means I cannot claim "tests pass" from inspection alone.
**Mitigation:** Phase 0 CI, and I treat a red run as blocking rather than advisory.

**R4 — The brief's performance target cannot be fully verified by me.** *Certain, low
impact.* "Interactive within 3 seconds on a normal connection" is a field measurement on
real devices and the plant network. I can measure bundle size, count blocking startup
work, and eliminate the unbounded await, but the 3-second acceptance test needs a
measurement from your side. **Mitigation:** I will add startup telemetry so the number is
observed in production rather than asserted, and report before/after against what I can
actually measure. I will not claim the acceptance criterion is met on the basis of code
inspection.

**R5 — Existing test coverage is five files.** *Certain, medium impact.* `crypto_utils`,
`validators`, `near_miss_guard`, `app_updater` and a widget smoke test. There is no
coverage of auth, sync, RLS behaviour or the workflow state machine, so regressions in
those areas will not be caught automatically. **Mitigation:** add tests alongside each
phase, prioritising the auth and role paths I am about to change, and treat the
unit-test step as blocking in CI from the start.

**R6 — Flutter 3.19.6 toolchain pin.** *Low likelihood, low impact.* `flutter analyze`
has never run on this codebase, so it starts with an unknown backlog of pre-existing
findings, and the Dart language level predates syntax I would otherwise reach for.
**Mitigation:** analysis is advisory in CI so inherited warnings do not fail every run,
tests and the release build are blocking, and I stay within the existing if-chain idiom.

**R7 — Hashing upgrade has a migration tail.** *Medium likelihood, low impact.* Rehashing
on login only upgrades users who actually log in; dormant accounts keep weak hashes
indefinitely, and `legacy-plain` (plaintext comparison) is still an accepted format today.
**Mitigation:** rehash-on-login plus a report of un-upgraded accounts for admin-forced
reset, and removal of the `legacy-plain` path in Phase 1C.

**R8 — Dual-backend drift.** *Medium likelihood, medium impact.* Supabase and Apps Script
both hold authority over overlapping data, and the Apps Script auth gate is
non-functional by design accident. Hardening Supabase alone leaves Apps Script as an
unauthenticated write path to the same records — closing RLS while `addIncident` remains
in `publicActions` would be a false sense of security. **Mitigation:** treat the Apps
Script surface explicitly in Phase 1C rather than assuming Supabase is the only door,
and document the finding regardless of whether it is fixed in that phase.

### Risks to the data

**R9 — Schema migrations against live data.** *Low likelihood, high impact.* Phase 1C and
Phase 3 both add columns. **Mitigation:** additive-only migrations, no destructive column
drops in any phase I am proposing, every migration paired with a documented rollback, and
— since you declined a separate staging Supabase project — I will ask you to take a
snapshot before any migration is applied. This is the residual risk I am least able to
mitigate on my own, and I will flag it again at the point of application.

**R10 — Two stray `- Copy.kt` files in `android/app/src/main/kotlin/`.** *Noted in
passing.* `MainActivity - Copy.kt` and `InstallResultReceiver - Copy.kt` are untracked
duplicates that will likely produce duplicate-class Kotlin compilation errors if they are
ever committed. Not urgent, relevant to Phase 4, recorded so it is not rediscovered.

---

## 5. What "done" means per phase

I will not report a phase complete on the strength of having written the code. Each phase
closes with: a green CI run (tests and release build), a manual walkthrough of the
affected flows against the preview artifact, the before/after numbers I can actually
measure, and an explicit statement of what remains unverified and why. Where the brief's
acceptance test requires a measurement I cannot take from here — field device performance,
screen-reader behaviour on real assistive technology, production network timings — I will
say so plainly rather than inferring it from the code.

---

## 6. Deliverable status

| # | Deliverable | Status |
|---|---|---|
| 1 | Updated source code | Phase 0 complete; 1A–1C in progress |
| 2 | Database migration scripts | Phase 1C |
| 3 | Environment variable template | Phase 1C (with the hardcoded-credential finding) |
| 4 | Architecture note | Phase 1C |
| 5 | API documentation | Phase 1C (RPC contracts), Phase 2 (contractor endpoints) |
| 6 | Role-permission matrix | Phase 1C |
| 7 | Test plan and automated results | Scaffolding complete; results per phase |
| 8 | Accessibility audit report | Phase 3 |
| 9 | Security audit report + dependency scan | Interim findings in this document; full report Phase 1C |
| 10 | Performance report | Phase 1A, subject to R4 |
| 11 | Staging deployment instructions | Phase 1A |
| 12 | Change log (Fixed/Added/Security/Performance/Accessibility) | Maintained from Phase 1A onward |
