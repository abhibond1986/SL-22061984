# Phase 1 status (updated 2026-09-27)

Branch: `hardening/enterprise-readiness`. Nothing here has been pushed to `main`, and `main` is the branch that deploys to safetylens.in.

| Part | State | What is left |
|---|---|---|
| 1A: startup fix and error boundaries | Done, CI green | — |
| 1B: landing page clarity | Committed (`95378b9`) | Push the branch and confirm `verify.yml` passes |
| 1C: access control, safe steps | Committed | Run the SQL, push the branch, check login on web and APK |
| 1C: lock-down (breaking step) | Not started, on purpose | Starts only after the safe steps are verified |

## 1B: what changed

The login screen now explains the product. It shows the brief's intro sentence, three feature cards, and the five-step "How it works" flow.

- **Wide screens (1000px and up):** the product intro is on the left and the sign-in panel is on the right.
- **Phones:** the sentence sits under the brand, and the cards and flow come after the sign-in actions.

The section is static, so it adds nothing to first-load time. It uses brand indigo only, carries screen-reader headings and step labels, and never uses `stretch` on a Row. It is covered by `test/landing_intro_test.dart` at 320–1440px in light and dark mode.

## 1C safe steps: what changed

### SQL: `supabase_rbac_phase1c.sql`

Run it in the Supabase SQL editor. It only adds things; it does not close any existing policy.

- **`role` column.** Admins are backfilled as `corporate_admin` and everyone else as `employee`. `is_admin` is kept, and a trigger keeps the two in sync both ways, so rollback is safe.
- **New-account guard.** A brand-new account is always created as `employee` / not admin, whatever the client sends. This means registration can never grant privilege.
- **`audit_events` table.** It is not readable or writable with the public key, and writes go through `sl_log_audit_event`. Role changes are logged by a database trigger, so they are recorded even when made outside the app.
- **`sl_verify_login` and `sl_account_status`.** The password is checked inside the database. Ten failures in 15 minutes locks that username for the rest of the window.
- **Check query at the end.** It lists the admin accounts, and at least one must exist (see the app changes below).

### App

- **Login.** Login calls `sl_verify_login` first. If the function is not installed yet, or does not recognise an older password format, the app falls back to the previous path. So this works before and after the SQL is run.
- **Admin panel.** The built-in `admin` / `admin` login is removed, along with the "Default: admin / admin" hint on screen. Only an account with admin rights can open the panel.
- **Ask AI.** Admin status no longer comes from words in the job title ("gm", "manager", …). It comes from the account flag only.
- **Audit log.** Admin audit entries are also sent to the server table, alongside the existing on-device log.

### Behaviour change to know about

When an admin creates a new user and ticks admin, the server now creates that user as an employee. Open the user again and switch admin on, and the edit is accepted.

## Still open after the safe steps

These are not done, so do not describe the system as locked down yet:

1. The `app_users` read, update and insert policies are still open to the public key. That means anyone with the key can still edit a row directly, including `is_admin`. Closing them needs two things first: admin edits and password changes must move to verified server functions, and the new login must be live on every platform.
2. `incidents` policies are still open. Closing them needs a server-issued session token at login.
3. Passwords are still salted SHA-256, because devices verify offline. Moving to an iterated KDF changes the credential format and is scheduled with step 1.
4. Contractor Access rate limiting and CAPTCHA belong to Phase 2.

## Screen sizes (all widths, phone to desktop)

Every main screen is now checked at 320, 360, 390, 600, 768, 1024, 1440 and 1920px, in light and dark mode, by `test/responsive/width_sweep_test.dart` (64 cases). It runs in CI as part of `flutter test`. It fails if any screen overflows its width.

What changed:

1. From 900px wide, both shells (employee and contractor) show a side navigation rail on the left instead of the bottom tab bar. Below 900px nothing changes.
2. Dialogs are capped at 560px wide. Before this, a confirmation dialog on a 1920px monitor stretched almost edge to edge. The full-screen image viewer is exempt.
3. Fixed overflows on narrow phones: the WSA-13 chart plant picker, the Near Miss dropdowns (long WSA causes and department names), the admin model and alert pickers, and the contractor app-bar title. Long option names now shorten with "…" instead of running off the screen.
4. Below 380px the language pill in the app bar shows only the language code, which gives the screen title more room. The SAIL Safety Lens wordmark on the login screen shrinks to fit instead of overflowing.

Not covered by the sweep: the admin Command Centre after sign-in (the test sees its login card), and pushed detail screens such as incident detail and Document Q&A. Those screens already sit inside the same width caps.
