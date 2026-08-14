# Safety Lens — current status

**Last verified: 2026-08-14** against the live repo and the Supabase REST API.

This file is the single place that states current reality. Every other markdown
file at the root is a point-in-time note from when a feature was built; those
describe what was true *that day*, not what is true now. Superseded notes have
been moved to `docs/archive/`.

---

## Outstanding deploy steps

These are the things that are broken or unverified right now. Nothing else in
this repo tracks them, which is why they kept getting missed.

### 1. Run `migration_workflow_fields.sql` — REQUIRED, causes data loss

Supabase → SQL Editor → New query → paste the whole file → Run.

The `incidents` table is missing eight columns the app actively writes:

```
investigation_started_at   action_taken_at   closed_by   closing_remarks
closed_at                  assigned_to       assigned_at target_date
```

Verified missing on 2026-08-14 (`select=closed_at` returns `42703`).

Why it matters: PostgREST rejects the **entire row** when one column is unknown.
So this is not "eight fields don't sync" — before the client-side guard below, it
meant *every* incident upsert failed once a record had been closed or assigned.
The user's closure remarks and corrective actions stayed on their device, and the
next realtime UPDATE could hand other devices a row without them.

Re-verify after running:

```bash
curl -s "$SUPABASE_URL/rest/v1/incidents?select=closed_at,closing_remarks,assigned_to,target_date&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
```

`HTTP 200` = fixed. `42703` = still missing.

### 2. Confirm `incidents` is in the `supabase_realtime` publication

Cannot be checked with the anon key. Without it, live cross-device updates never
fire. Supabase → Database → Replication.

### 3. Confirm `apps_script_v14.js` was redeployed

Lives at the **repo root** (not in `apps_script/`, which only holds
`AlertSystem.gs`). Last changed in commit `01f3a87`. It is the AI proxy — API
keys live in its Script Properties — so it cannot be removed, and the new
`INCIDENT_COLS` headers only take effect after a redeploy.

### Already done — do not re-run blindly

`supabase_ai_runs_setup.sql` and `supabase_ai_corrections_setup.sql` have both
been applied; the `ai_runs` and `ai_corrections` tables exist and hold rows.

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
- **145 sites** at 8-9px, plus 191 at 10px. Raising these is a one-line change
  each and cannot break compilation, but it can change dense analytics layouts,
  so it needs a visual pass.

The bare `AppColors` status tokens are left deliberately failing as text so the
audit keeps flagging any reintroduction. They are correct as **fills**.

## Verification limits

There is no Flutter SDK in the agent sandbox, so **no change made by an agent has
been compiled.** CI (Flutter 3.19.6) is the first real compile — avoid Dart 3
record/pattern switch expressions. Keep `.gitattributes` (`* text=auto eol=lf`);
a Windows checkout once flipped the tree to CRLF and turned a 22-file diff into
171.
