# Safety Lens — current status

**Last verified: 2026-08-14** against the live repo and the Supabase REST API.

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

This is now the only unverified deploy step.

### 2. Confirm row-level security is enforced on `incidents`

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

## Verification limits

There is no Flutter SDK in the agent sandbox, so **no change made by an agent has
been compiled.** CI (Flutter 3.19.6) is the first real compile — avoid Dart 3
record/pattern switch expressions. Keep `.gitattributes` (`* text=auto eol=lf`);
a Windows checkout once flipped the tree to CRLF and turned a 22-file diff into
171.
