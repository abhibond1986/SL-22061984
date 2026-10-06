# Audit 2026-10-06: Safari login fails with credentials that work on the laptop

**Report.** "I am not able to login in my Safari web browser with the same credentials I use on my laptop."

## Root cause

The accounts and the password check are the same on every browser. Login goes local cache → Supabase `app_users`, and the hashing is the app's own pure-Dart SHA-256, which gives the same result in every JavaScript engine. So the difference is in what Safari sends, not in the server.

The Flutter web engine (3.19.6, `_engine/engine/text_editing/text_editing.dart` line 1280) sets `autocorrect="on"` on every input unless the TextField turns it off. That attribute is only honoured by WebKit, i.e. Safari on iPhone, iPad and Mac. The login and register fields never turned it off. In Safari:

- the **Username** box was autocorrected. iOS commits the correction when the keyboard's Next/Go key is pressed, and macOS applies system spelling correction. A username such as a P.No. or a short name could be changed into a dictionary word before it was sent;
- tapping a QuickType suggestion appends a **space**;
- with **Show password** on, the password becomes an ordinary text input, so autocorrect, smart quotes and smart dashes could alter it as well.

Chrome and Edge ignore the attribute, which is why the same credentials worked on the laptop.

## Fix

- `login_screen.dart` `_field`: credential fields (username, new-username, password and new-password autofill hints) now set `autocorrect: false`, `enableSuggestions: false`, smart dashes/quotes disabled and `TextCapitalization.none`. Password fields use `TextInputType.visiblePassword`. The autofill hints are unchanged, so browser and iCloud Keychain password filling still works. Name, designation and similar fields keep autocorrect.
- `force_password_change_screen.dart`: the same settings on the new and confirm password fields, plus the `newPassword` autofill hint.
- `auth_service.dart` `_matchLoginPassword`: if the exact password fails, it retries once with leading and trailing whitespace trimmed. The exact value is always tried first, so a password that really ends in a space still works. Case and other typos are still rejected.

## Verification

- `dart analyze lib`: 52 issues, 0 errors (same as the baseline).
- `tools/auth_trim_test.dart` passes. The exact password is accepted, the same password with a trailing space is accepted, and wrong-case and truncated passwords are rejected.
- The login render tests (phone and desktop) pass.
- The server was probed: 10,123 `app_users` rows, every one with a salt (no legacy unsalted rows). Only 42 accounts have set their own password; the rest are still on the first-login P.No.
- Not verifiable in the sandbox: a real Safari session. Please confirm after deploy.

## Limitation

If a password was ever **set** in Safari with Show password on, the stored password may itself be the autocorrected text. In that case use "Forgot password?" (P.No. or mobile check) once to set it again.

---

## Follow-up: the real cause, `QuotaExceededError` (iPhone Safari and iPhone Chrome)

**Report.** The user sent a screenshot from iPhone Safari after the deploy: "Login failed: QuotaExceededError: The quota has been exceeded." The same thing happens in Chrome on iPhone, and the app "is crashing". The autocorrect change above is still correct, but it was not the cause.

**Root cause.** On the web, SharedPreferences is `localStorage`.

- iPhone Safari's engine (WebKit) caps it at about 5 MB per site. Every iPhone browser, including Chrome, must use WebKit.
- Values are JSON-encoded twice and counted as UTF-16, so a stored value takes roughly twice its size.
- `LocalDB` cached the knowledge base there. The server's newest 1,000 `knowledge_docs` are **2.73 MB of JSON**, 2.4 MB of which is the `content` text (measured live). The user directory cache adds another 0.70 MB.
- That fills the store. After that, **every** write throws, including `LocalDB.upsertUser` and `setCurrentUser` inside `AuthService.signIn`. The exception reached the login screen as "Login failed: QuotaExceededError". Other screens that write locally failed the same way, which is the "crashing".
- Desktop Chrome allows roughly twice as much, so the laptop worked.

**Fix (`lib/services/local_db.dart`).**

- All 43 `setString`, 24 `getString` and 18 `remove` calls in LocalDB now go through `_put`, `_get` and `_del`.
- **Web: session-only caches.** `kb_documents` and `cached_users` are held in memory and not persisted, because they are re-pulled from the server on every load (the KB pull timer is in memory). The exception is KB docs that exist only on this device (`cloudSynced != true`): those are still persisted, so nothing that hasn't been uploaded is lost.
- **Migration on load.** `_migrateWebStorage()` moves any existing `kb_documents` and `cached_users` out of localStorage into memory, freeing a browser that an older build had already filled. No user action is needed; the fix works on the next page load.
- **Quota-safe writes everywhere.** On a quota error, `_write` drops the expendable keys (`ai_result_cache_v1`, `ai_runs_log`, `app_error_logs`, `error_logs`) and retries once. If it still doesn't fit, the write is skipped with a log line and returns false; it never throws. SharedPreferences updates its in-memory copy before the platform write, so the session carries on normally.
- Saving an incident keeps its earlier fallback: if the write fails, it keeps the newest 50 incidents. This now checks the return value instead of catching the exception.

**Verification.**

- `tools/storage_quota_test.dart` uses a store that throws "QuotaExceededError: The quota has been exceeded." once it is full.
  - On the **old** `local_db.dart` it fails with exactly that exception, reproducing the user's screenshot.
  - On the new code it passes: sign-in succeeds, the expendable cache is evicted to make room, and an oversized write is dropped without throwing and is still readable in the session.
- `tools/auth_trim_test.dart` passes.
- `dart analyze lib`: 52 issues, 0 errors (same as the baseline).
- The web build is compiled by GitHub Actions on push. Please re-test on the iPhone after the deploy.

**Trade-off.** On the web, the KB and user directory are fetched again on each page load. Both pulls were already happening on load, so this adds no requests. Offline web use loses the cached KB, but the Android app is unaffected because the session-only rule applies to the web only.
