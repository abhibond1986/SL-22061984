# Audit (2026-10-30): Hindi text in PDF reports, one-time device permissions, My Profile

## Request

The owner asked for two things.

1. After login, ask once for camera and microphone (location was added on the owner's choice). Remember the answer at every later login. Let users change it from their profile, where they can also update their own details.
2. A near miss typed in Hindi produced a PDF without the Hindi text. Every report should print the language it was written in.

The owner made three decisions on 30 Oct:

- **PDF labels:** labels stay in English, and the user's text prints in Hindi exactly as typed.
- **Editable profile fields:** mobile, email, designation, department and unit. Name, P.No, grade and plant stay with the HR import.
- **Permissions to ask for:** camera, microphone and location.

## Status

- **Code:** applied to the working tree. It is not committed and not pushed.
- **Build checks:** `dart analyze lib` shows 49 issues, the same as before the change. The 2 errors are the existing ones in `lib/test_key_sync.dart`, and no new warnings were added.
- **Tests:** the new tests and the related existing ones pass.
- **One unrelated failure:** `test/validators_test.dart` "valid passwords pass" already fails before this change. The test expects a password the validator rejects. Neither file was touched.

## 1. Hindi in PDF reports

### Root cause

The report uses the PDF built-in Helvetica font, which only covers Latin-1 characters. For every Devanagari letter the `pdf` package logs "Unable to find a font to draw क" and prints an empty box. We reproduced this with the old code (`audit_2026-10-30/pdf_hindi_BEFORE.png`).

Embedding a Hindi font alone would not fix it. The `pdf` package (version 3.11.3 in our lockfile) has no text shaping for Indian scripts; it only shapes Arabic. Without shaping:

- The ि matra prints after its consonant, so हिंदी reads wrong.
- Half-forms and conjuncts (क्ष, त्र, श्र) fall apart.

On a statutory safety record that is effectively misspelt text, so this was rejected.

### Fix

Each non-Latin word is drawn by a real text engine and placed in the report as a small high-resolution image (about 320 dpi at 9 pt).

- **App:** Flutter's own engine draws the words, using the bundled Noto Sans Devanagari font (`assets/fonts/`, SIL Open Font Licence, about 490 KB).
- **Web:** the browser's canvas draws them, with the same font loaded into the page. If that fails, it falls back to the system Devanagari font (Nirmala UI on Windows, Kohinoor on iPhone and Mac, Noto on Android). This works with both web renderers, including the HTML renderer that mobile browsers get.
- **Word by word:** shaping never crosses a space, so drawing one word at a time is exact. The words flow in a `pw.Wrap`, so line breaks follow the column width.
- **Mixed sentences:** English words inside a Hindi sentence stay real Helvetica text, aligned on the same baseline.
- **Other scripts:** Bengali, Odia, Tamil and so on take the same path, using the device's fonts.

### Wiring

`pdf_export.dart` imports `package:pdf/widgets.dart` as `pw` with `hide Text`, and imports `pdf_text.dart` under the same `pw` prefix. All 81 existing `pw.Text(...)` calls therefore reach the new `Text` function:

- Latin-1 text gets the original `pw.Text`, so English output is unchanged.
- Anything else gets the shaped word images.

The images must exist before page layout, which is synchronous. So `PdfScript.run` builds the report twice, and only when it contains non-Latin text. The report builder has no side effects, so building it twice is safe. The consolidated report goes through the same path.

### Evidence

All files are in `audit_2026-10-30/`.

| File | What it shows |
|---|---|
| `pdf_hindi_BEFORE.png` | The old code: every Hindi word prints as boxes |
| `pdf_hindi_AFTER.png` | The new code: title, location, reporter, summary and corrective actions all print in Hindi. क्रेन, क्षतिग्रस्त, श्रमिक and सुनिश्चित render correctly, mixed "EOT crane से" is baseline-aligned, and English labels are unchanged |
| `pdf_english_unchanged.png` | An English report, built in a single pass, identical in layout |

Test: `tools/pdf_hindi_test.dart`. The regression test `tools/pdf_regulation_column_test.dart` also passes.

### Risks and limits

- **Not searchable.** Hindi words in the PDF are pictures, so they cannot be selected or searched in a PDF viewer.
- **File size.** A Hindi page grows to about 150 KB (the English one is 30 KB).
- **Row height.** A Hindi line is a little taller (1.38 em against 1.16 em), so mixed rows grow slightly. The test report stays on one page.
- **Web untested.** The web drawing path could not be run in the sandbox, which has no browser. Check it on safetylens.in on Chrome desktop, Android Chrome and iPhone Safari before relying on it. If it fails, each word falls back to the embedded TTF font: still legible and never crashing, but unshaped.
- **`maxLines`.** Hindi text in a one-line slot shrinks to fit. Other `maxLines` limits are not applied to Hindi text; it wraps instead.

## 2. One-time camera, microphone and location request

### Behaviour

- **After login:** HomeScreen (and the contractor screen) shows the sheet once (`permission_onboarding.dart`). It has a ticked checkbox for each permission plus "Not now" and "Continue".
- **Continue:** asks the device or browser for each ticked item, one at a time.
- **Not now:** records all three as off.
- **Stored per user, per device:** the answer is kept under `device_perm_v1_<username>` and the sheet is never shown again for that account on that device. A new phone asks once, because a permission granted on one device means nothing on another.
- **Skipped when not needed:** if everything is already allowed, nothing is shown and the answer is recorded silently.

### When a feature is off

Before using the camera or microphone, the app checks the user's choice (`DevicePermissions.guard`).

- **Feature on:** nothing changes.
- **Feature off:** the user is asked "Camera is turned off. Turn it on now?" instead of seeing a system prompt. "Turn on" asks the device for permission.
- **Blocked by the OS or browser:** the user gets short instructions to undo it (Settings on the phone, the padlock icon in the browser), with an "Open settings" button in the app.

Where the check is applied:

- **Camera:** AI Scan (scan and manual photo), Near Miss, SOP Scan (add pages and retake), and the incident action photo.
- **Microphone:** Near Miss voice input and VoiceTextField.
- **Location:** `GeoService` skips GPS when the user turned location off. Reports then carry no coordinates, and photo EXIF location still works.

### Platform code

- **Android and iOS:** `device_permissions_io.dart` uses permission_handler.
- **Web:** `device_permissions_web.dart` uses `getUserMedia` (the stream is stopped immediately), the geolocation API, and `navigator.permissions` for status.
- **iOS native build:** `ios/Podfile` now sets the permission_handler macros. Without them, iOS reports these permissions as permanently denied.

### What the app cannot do

- **Revoke a permission.** The app cannot switch off an OS or browser permission. The Profile switch is the user's choice inside Safety Lens; the device setting is shown beside it.
- **iPhone Safari.** Safari may ask again in a new session unless the site is set to "Allow". The Profile help text says so.
- **Firefox.** Firefox cannot report camera or microphone status, so it shows "Will ask when used".

### Evidence

All files are in `audit_2026-10-30/`.

| File | What it shows |
|---|---|
| `perm_sheet_phone_light.png` | The one-time sheet on a phone, light theme |
| `perm_sheet_phone_dark_hi.png` | The sheet in dark theme, in Hindi |
| `perm_sheet_laptop_dark.png` | The sheet on a laptop |
| `perm_guard_dialog.png` | The "Camera is turned off" dialog |

Behaviour tests in `tools/profile_permissions_render_test.dart` check four things:

- the answer survives a "logout and login";
- usernames are matched case-insensitively;
- a Profile change persists;
- a feature switched off asks first, and "Keep off" blocks it.

## 3. My Profile

### Where and what

- **Opening it:** "My Profile" is the first row in the avatar menu (`my_profile_screen.dart`). The contractor screen gets a shield icon that opens the permissions part only.
- **Read-only:** name, P.No, grade and plant, with a note that they come from the HR list.
- **Editable:** mobile (Indian 10-digit; +91 or a leading 0 is accepted), email (validated), designation, department (free text plus a pick-list from Admin master data) and unit.
- **Permissions:** a switch for each permission, with the live device or browser status beside it.

### Saving

- **Server:** `SupabaseService.updateOwnProfile` sends an UPDATE of only those five columns plus `updated_at`. It never upserts the whole row, so a stale device copy cannot revert anything else.
- **Device:** the device copies are refreshed (current user and user directory), and the shell reloads through `currentUserRevision`, so the app bar and Near Miss defaults show the new values.

### Kept through the quarterly HR import

- `self_edited_fields` records which fields the user edited.
- `UserImportRunner` replaces the file's value with the user's current value for those fields. Every row keeps the same keys, as PostgREST bulk upserts require.
- The import result says "N kept their own profile edits".
- If that list cannot be read, the import reports it rather than silently overwriting.

### Needs one SQL step

Run `migration_profile_self_edit.sql` in Supabase. It adds two columns and is safe to run more than once.

Until it is run, edits still save, but the app tells the user the next HR refresh may overwrite them.

### Evidence

All files are in `audit_2026-10-30/`.

| File | What it shows |
|---|---|
| `profile_phone_light.png` | My Profile on a phone, light theme |
| `profile_phone_dark_hi.png` | My Profile in dark theme, in Hindi |
| `profile_laptop_dark.png` | My Profile on a laptop |

### Security note

This uses the existing open `app_users` UPDATE policy, which was flagged earlier and is still unfixed. It adds no new exposure: anyone with the anon key could already update any row. It would become properly safe once that policy is tightened, through a security-definer function keyed to the session.

## Files

**New:**

- `lib/services/pdf_text.dart`, `pdf_text_raster_io.dart`, `pdf_text_raster_web.dart`
- `lib/services/device_permissions.dart`, `device_permissions_io.dart`, `device_permissions_web.dart`
- `lib/widgets/permission_onboarding.dart`
- `lib/screens/my_profile_screen.dart`
- `assets/fonts/` (Noto Sans Devanagari Regular and Bold, plus OFL.txt)
- `migration_profile_self_edit.sql`
- `tools/pdf_hindi_test.dart`, `tools/profile_permissions_render_test.dart`

**Changed:** 16 files, 428 lines added and 10 removed:

- `pdf_export.dart`, `supabase_service.dart`, `user_import_runner.dart`, `i18n.dart` (about 50 English and Hindi strings), `geo_service.dart`
- `home_screen.dart`, `contractor_home_screen.dart`, `universal_app_bar.dart`
- the camera and microphone check in `ai_scan_tab.dart`, `near_miss_tab.dart`, `sop_scan_screen.dart`, `incident_detail_screen.dart` and `voice_text_field.dart`
- `pubspec.yaml` (adds `assets/fonts/`), `ios/Podfile`, `STATUS.md`

## Deploy

1. Review, then on Windows: `git add -A`, `git commit -m "Hindi in PDF reports; one-time device permissions; My Profile"`, `git push`. The `wip_2026-10-30/` folder can be deleted first, since it is only the staging copy.
2. Run `migration_profile_self_edit.sql` in the Supabase SQL editor.
3. After GitHub Pages deploys, check:
   1. A Hindi near miss PDF on Chrome desktop, Android Chrome and iPhone Safari. This is the one path not tested here.
   2. A fresh login on a phone shows the sheet once, and a second login does not.
   3. Switching the mic off in My Profile makes Near Miss ask before listening.
   4. Editing your mobile in My Profile shows in the avatar menu.

## Rollback

`git revert` the commit. Nothing is migrated destructively. The two new columns can stay, or be dropped with the commented lines in the SQL file. Stored permission answers are just unused keys in local storage.

## Watch-outs

- **Two prompts at once.** On Android 13+, the push-notification prompt (NotificationService, started at the same moment) and this sheet can appear together. The sheet only asks after the user taps Continue, so their system prompts do not overlap.
- **A sheet left open.** If a user signs out while the sheet is open, the sheet is shown again at the next login, because no answer was recorded. That is intended.
