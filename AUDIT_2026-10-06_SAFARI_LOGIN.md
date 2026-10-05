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
