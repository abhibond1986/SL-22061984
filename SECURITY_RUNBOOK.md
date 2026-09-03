# Runbook — closing the Apps Script key exposure

Written 2026-09-03. Everything in this file is a manual step: it needs consoles
and credentials that no agent has. The code changes are already in the working
tree (uncommitted); this is what makes them take effect.

Read the ordering rules first — two of the steps break the app if done early.

---

## The two ordering rules

1. **`APP_SECRET` must exist in Script Properties BEFORE you redeploy.**
   The check fails closed: with no property set, the backend refuses `getAiKeys`
   and `gemini` outright. That is intentional — a check that falls back to
   "allow" when misconfigured is not a check. But it means redeploying first
   gives you a window where the app has no AI at all.

2. **Rotate keys AFTER the hole is closed, not before.**
   Rotating into a deployment that still hands keys to anonymous callers just
   publishes the new keys too. Close first, then rotate.

---

## Step 1 — Set the script property

Apps Script editor → ⚙ Project Settings → Script Properties → Add property.

| Property | Value |
|---|---|
| `APP_SECRET` | a long random string, 32+ chars |

Generate one with anything you trust, e.g. in a terminal:

```
openssl rand -hex 32
```

Keep it somewhere you can paste it again in step 2. It is not recoverable from
the Script Properties UI later without opening that panel again, and it must
match the app byte for byte (the check compares after `trim()`, nothing else).

---

## Step 2 — Add the matching repository secret

GitHub → the repo → Settings → Secrets and variables → Actions → New repository
secret.

| Name | Value |
|---|---|
| `SL_APP_SECRET` | the exact same string as `APP_SECRET` |

Both workflows already read it (`build-web.yml`, `build-apk.yml`) and pass it as
`--dart-define=SL_APP_SECRET=...`. If the secret is missing, the build still
**succeeds** — `String.fromEnvironment` just yields an empty string — and then
every AI feature silently degrades to offline analysis. There is no build error
to warn you. That is the failure mode to watch for.

---

## Step 3 — Paste the new script and REDEPLOY

Copy `apps_script_v14.js` over the editor contents, save, then:

Deploy → **Manage deployments** → the existing deployment → ✏ (edit) → Version:
**New version** → Deploy.

**Saving the editor is not deploying.** The `/exec` URL serves the last
*deployment*, not the last save. Skipping this is the single most common way this
work appears to have had no effect. Editing the existing deployment (rather than
"New deployment") keeps the same `/exec` URL, which matters because that URL is a
compile-time constant in the app.

Confirm afterwards with a plain browser hit:

```
https://script.google.com/macros/s/<id>/exec?action=health
```

should answer, and

```
POST {"action":"getMasterData"}
```

should come back **without any `*ApiKey` field**. That is the actual test of
whether the exposure is closed. Also confirm `{"action":"diagnose"}` now returns
an unknown-action error — it used to spend money per call.

---

## Step 4 — Rebuild and deploy the app

Push the commit (or run both workflows via workflow_dispatch). Both targets need
it: an old APK in someone's hand keeps sending no `_appSecret` and will lose AI.

Check the browser console on safetylens.in after deploy. If you see

```
SyncService: getAiKeys refused — Forbidden: bad or missing _appSecret
```

the two values do not match, or the repository secret was missing at build time.
The log line also prints whether a secret was compiled in at all, which tells you
which of the two it is.

---

## Step 5 — Rotate all five vendor keys

Assume every key issued before today is public. Rotate, do not merely add:

| Key | Where |
|---|---|
| Gemini / Google AI | Google AI Studio → API keys |
| OpenRouter (both) | openrouter.ai → Keys |
| Groq | console.groq.com → API Keys |
| Nara | vendor console |

**Three of these are recoverable from this repository's git history** — one
Gemini key and two OpenRouter keys. Rotating is not enough for those: **revoke
the old ones**. History rewriting is not required and not recommended; revocation
is what makes the leaked strings worthless.

Update each new key in Script Properties, then let the app pull them via
`getAiKeys` (it refreshes pre-launch and every 5 minutes from `BackgroundSync`).

While you are in each console, two cheap protections:

* **Spend cap / budget alert per vendor.** The `gemini` action is a billable
  proxy and the app holds keys client-side; a cap is the only thing that bounds
  the damage from the next leak.
* **HTTP-referrer restriction on the Gemini key**, limited to `safetylens.in`.
  Note this does nothing for the APK — referrer restrictions are a browser
  mechanism — and nothing for a non-browser caller, but it does neuter a key
  scraped out of the web bundle.

---

## Step 6 — Supabase (separate issue, separate decision)

`supabase_app_users_hardening.sql` — Supabase dashboard → SQL Editor → New query
→ paste → Run. Idempotent.

* **Sections 1 and 2 are additive.** They add `verify_login`, `account_status`
  and `list_app_users_safe`. Nothing breaks. Run them whenever.
* **Section 3 is commented out and must stay that way for now.** It closes the
  read on `app_users`, which breaks login on every device — including old APKs —
  until the Dart client calls `verify_login` instead of fetching and comparing
  the hash locally. The required Dart changes are listed at the bottom of the SQL
  file. Rollback is one statement, so it is a quiet-hour experiment, not a
  one-way door.

What this does *not* fix, and cannot fix with policies alone: the `UPDATE` policy
is `using (true)`, so anyone holding the anon key can overwrite any user's
`password_hash` — account takeover — and `INSERT` lets anyone create an
`is_admin = true` account. Both need `security definer` functions that demand
proof (old password, or a reset token) before the policies can be closed. There
is no server-verifiable identity in the app today.

---

## What is still open after all of this

This runbook closes an *anonymous internet* hole. It does not make the keys
secret.

* On web, `SL_APP_SECRET` is compiled into the JavaScript the browser downloads,
  and `main.dart:65` fetches master data before `runApp`, so keys land in
  `SharedPreferences` before the login screen paints. Anyone with the build can
  read them from DevTools.
* Nine code paths call vendor APIs directly from the device with a key out of
  prefs (`groq_service`, `gemini_vision`, `gemini_direct_vision`, `nara_vision`
  on mobile, four paths in `sop_ocr_service`, `ai_audit_service`). Only
  `doc_qa_service` goes through a proxy.

**The real fix is step 3 of the original plan: proxy every vendor call through
Apps Script so no key ever reaches a device.** `DocQaProxy.gs` is the working
pattern to copy. Until then, `lib/services/app_secret.dart` is a stopgap and its
doc comment says so.

Also unauthenticated and untouched by this pass: `addIncident`, `updateIncident`,
`updateIncidentStatus`, `listIncidents`, `addKnowledge`, `listKnowledge`,
`uploadPdfToDrive` and the sheet-format actions — open reads and writes of plant
incident data. Anyone who has read the repo can post to them.
