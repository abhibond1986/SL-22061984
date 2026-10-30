# Work in progress (30 Oct 2026): Hindi PDF, one-time permissions, My Profile

Nothing in `lib/` has been changed yet. Everything is staged in this folder and is applied by one script. The only file already edited in the app is `ios/Podfile` (see section 4).

## What the owner asked for

1. **Permissions.** After login, ask once for camera, microphone and location. Remember the answer at every later login. Let the user change it in their Profile, where they can also update their own details.
2. **Hindi PDF.** A near miss written in Hindi printed empty boxes in the PDF. Any report should print the language it was written in.

Decisions the owner made on 30 Oct:

- **Editable profile fields:** contact and job details (mobile, email, designation, department, unit). Name, P.No, grade and plant stay read-only, because they come from the HR import.
- **PDF labels:** English labels, with the user's text in Hindi exactly as typed.
- **Permissions to ask for:** camera, microphone and location.

## 1. Hindi in PDF: DONE and render-verified

**Root cause.** The report uses the built-in Helvetica font, which only covers Latin-1. Every Devanagari letter printed as an empty box (see `renders/pdf_hindi_BEFORE.png`). Embedding a Hindi font alone would not fix it: the `pdf` package (3.11) has no Indic text shaping, so conjuncts and vowel signs (matras) would print in the wrong order.

**Fix.** The new files are `pdf_text.dart` and two helpers, `pdf_text_raster_io.dart` (app) and `pdf_text_raster_web.dart` (browser).

- Each non-Latin word is drawn by a real text engine and placed in the report as a sharp image (about 320 dpi). In the app that is Flutter's own engine; on the web it is the browser's canvas.
- The bundled Noto Sans Devanagari font is used (SIL OFL licence).
- Latin words in a Hindi sentence stay as normal text, aligned on the same baseline.
- `pdf_export.dart` imports the pdf widgets with `hide Text` and brings in `pdf_text.dart` under the same `pw` prefix. As a result, all 81 existing `pw.Text` calls now go through the fix.
- `PdfScript.run` builds the report twice, and only when it contains non-Latin text. English reports are built once and come out exactly as before.

**Result.** See `renders/pdf_hindi_AFTER.png` and `pdf_hindi_AFTER_zoom.png`: क्रेन, क्षतिग्रस्त and श्रमिक all print correctly.

**Trade-off.** The Hindi words cannot be selected or searched in a PDF viewer.

**Not yet tested:** the web path (`pdf_text_raster_web.dart`). There is no browser in the sandbox, so it needs one live check on safetylens.in in Chrome and on an iPhone.

## 2. One-time permissions: CODE WRITTEN, not yet compiled together

New files:

- **`device_permissions.dart`:** stores each user's choice per device under `device_perm_v1_<username>`, and provides `guard()`, the check each feature calls before use. It works with `device_permissions_io.dart` (Android/iOS, via permission_handler) and `device_permissions_web.dart` (browser `getUserMedia` and geolocation).
- **`permission_onboarding.dart`:** the sheet shown after login. It has a checkbox for each permission plus "Not now" and "Continue". It is shown once per user per device, and skipped if everything is already allowed.

Where it is wired in (by the script):

- HomeScreen, after login.
- ContractorHomeScreen, keyed as 'contractor', with a shield icon that opens the permission settings.
- A camera check before every camera capture: AI Scan (scan and manual photo), Near Miss, SOP Scan (add pages and retake), and the incident action photo.
- A microphone check in Near Miss voice input and in VoiceTextField.
- `GeoService` returns no location if the user switched it off.

## 3. My Profile: CODE WRITTEN, not yet compiled together

- **Where to find it.** `my_profile_screen.dart`, opened from a new "My Profile" row in the avatar menu (UniversalAppBar).
- **What the user can edit.** Mobile, email, designation, department (with a pick-list from master data) and unit. The HR fields are shown read-only. The Device permissions section has a switch and a live device status for each permission.
- **How it saves.** `SupabaseService.updateOwnProfile` updates only those columns. It also records `self_edited_fields`, and `UserImportRunner` then keeps the user's own values at the next quarterly import.
- **SQL to run once.** Run `migration_profile_self_edit.sql` in Supabase. Until it is run, edits still save, but the app warns that the next import may overwrite them.
- **Translations.** Hindi and English strings are in `snippet_i18n_*.txt`.

## 4. Already changed in the repo

`ios/Podfile` now sets the permission_handler macros: PERMISSION_CAMERA, PERMISSION_MICROPHONE, PERMISSION_SPEECH_RECOGNIZER and PERMISSION_LOCATION. Without them, iOS reports these permissions as permanently denied. This only matters for a native iOS build. Web and Android are unaffected.

## To resume

1. Copy the project to a scratch folder. Then run `python3 wip_2026-10-30/apply_changes.py <copy>`. The script is idempotent.
2. Run `flutter pub get` and `dart analyze lib`. The baseline before these changes was 49 issues and 0 errors in `lib/`; the 2 errors are pre-existing ones in `lib/test_key_sync.dart`.
3. Run `flutter test tools/pdf_hindi_test.dart` and check the rendered PDF.
4. Render the permission sheet and the My Profile screen, light and dark, at phone and laptop sizes.
5. Do the pre-deployment audit, write `AUDIT_2026-10-30_*.md` and a STATUS.md note, then apply the script to the real repo.
6. Deploy steps for the owner: `git push`, then run the SQL migration.
