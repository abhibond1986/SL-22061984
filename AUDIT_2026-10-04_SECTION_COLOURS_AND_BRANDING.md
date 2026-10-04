# Audit 2026-10-04: incident detail section colours and company branding

## Request

> "give different sections of this page some standard and professional color. Also give an option in the admin panel to update company name and logo so that this app can be customised for different companies"

## 1. Section colours (incident detail page)

**File:** `lib/screens/incident_detail_screen.dart`.

Every card on the page is now built by one helper, `_section(sl, bg, title:, icon:, color:, child:)`. The helper draws:

- a tinted header band, with the icon tile and an UPPERCASE title in the section colour, and a hairline underneath;
- a matching border at about 22% opacity, clipped to the 12 px radius.

The border is uniform, which avoids the borderRadius / non-uniform-border assertion.

The colours live in one place, `_SecColors`. They are muted 700-weight tones, so the severity and status colours stay the loudest things on screen.

| Section | Colour | Hex |
|---|---|---|
| Case details | navy | `#1E3A8A` |
| Description | slate | `#475569` |
| Immediate action at site | amber | `#B45309` |
| Hazards identified | deep red | `#B91C1C` |
| Quick actions | indigo | `#4338CA` |
| Mitigation & closure | teal | `#0F766E` |
| Case closed | green | `#15803D` |
| View only | grey | `#64748B` |
| Timeline | blue-grey | `#334155` |

In dark mode, the header text is lightened by 50% toward white, and the band and border are given more opacity.

Other changes in this file:

- `_secLabel` and `_infoBox` had no callers left, so they were removed.
- **Fix:** hazard severity pills were truncated to 4 letters ("MEDI"). They now show the full word.

**Evidence** (in `audit_2026-10-04/`):

- `detail_laptop.png`: light theme.
- `detail_dark.png`: dark theme.
- `detail_closed.png`: closed case, showing the Case closed and Timeline sections.
- `detail_phone.png`: single column.
- Render harness: `tools/detail_render_test.dart`, now with dark and closed cases.

## 2. Company branding (white-label)

### Admin UI

There is a new module: **Admin → Company Branding** (id 17, "Name & logo"). It lives in `lib/screens/admin/branding_panel.dart` and contains:

- **Company name** (required, up to 80 characters). This is printed at the top of every PDF.
- **Short name** (up to 12 characters). The app becomes "`<short>` Safety Lens"; leave it empty for plain "Safety Lens".
- **Logo**, with these controls:
  - Upload accepts PNG, JPG or WEBP up to 8 MB.
  - The image is decoded, its longest edge is capped at 512 px, and it is re-encoded as PNG with transparency kept.
  - "Use default" reverts to the bundled logo.
- **Live preview** of the app header and of the PDF masthead (on a risk-coloured band).
- **Save branding** (enabled only when something changed) and **Reset to SAIL default** (asks for confirmation first).
- Every save writes an `AdminAudit` `settings_changed` entry with before/after values and whether the change synced.

### Storage and sync (`lib/services/branding.dart`)

- **Local cache:** `SharedPreferences['branding_v1']` (JSON). `Branding.load()` runs in `main()` before `runApp`, so the first frame is already branded.
- **Shared copy:** the Supabase `master_data` row `branding`.
  - Pushed by `SyncService.pushMasterData(branding:)`.
  - Pulled through the `pullMasterData` whitelist into `AdminMasterData.syncFromBackend()`, which calls `Branding.applyRemote()`.
  - Last write wins on `updatedAt`, so a pull cannot undo a save whose push has not landed yet.
- **Change notification:** `Branding.revision` is a ValueNotifier. Everything listens to it, so a change shows immediately without a restart.

### Where the brand appears

| Surface | Change |
|---|---|
| All logo sites | Now use `BrandLogo`: splash, login, universal app bar, dashboard, contractor home, `SailLogoTile`, `SailLogo`. A custom logo sits on a small white rounded tile so it stays visible on dark or gradient backgrounds. |
| App name | `BrandTitle` (header wordmark), the MaterialApp window/tab title, dashboard and contractor titles, and the admin login and drawer captions. |
| Share texts | WhatsApp, email and system-share captions and subjects (detail, AI scan, near-miss); the fallback reporter name ("ACME Safety Officer"); the AI text-corrector prompt. |
| PDF | Masthead company line, logo (custom logo on a white tile over the risk colour; bare on the continuation header), footer, disclaimer, consolidated report title, share captions, and the text-mark fallback. |

**Left unchanged on purpose:** the backup file signature `'SAIL Safety Lens V2'`, since changing it would stop old backups restoring, and the Google Drive folder name, which is a config path and not display text.

**Evidence** (in `audit_2026-10-04/`):

- `branding_panel_default.png` and `branding_panel_custom.png`.
- `branding_chrome_custom.png`: logo tile and title, dark background.
- `branding_report-1.png` and `branding_report.pdf`: a PDF generated with the "ACME Metals & Mining Corporation" test brand.
- Harness: `tools/branding_render_test.dart`, 3 tests, all passing.
- In the harness, `BrandTitle` itself is replaced with plain text because google_fonts needs the network.

## Verification

- `dart analyze lib`: 0 errors, 53 issues, the same pre-existing baseline as before. The new files produce no issues.
- Not yet checked on a device or on the live site.

## Known limits and follow-ups

1. **Build-time assets are not covered.** The browser tab title and favicon (`web/index.html`, `web/manifest.json`, web icons), the Android/iOS launcher icon and the native splash are baked into the build. Re-branding those needs new assets plus a rebuild.
2. **Legacy Apps Script backend.** `branding` is sent in the payload, but `MASTERDATA_KEYS` in `apps_script_v14.js` does not include it yet. This is harmless while Supabase is the live path.
3. **Other SAIL-specific content remains:**
   - The Plant Master defaults (14 SAIL units, codes such as BSL expanding to "Bokaro Steel Plant"). These can already be edited in Admin → Plant Master.
   - The Hindi `appName` string. It is used only when the brand is the default.
4. **Logo size.** Logos are stored inline as base64 (about 50–300 KB after resizing). That is fine for one jsonb row, but it should not be raised much past 512 px.
5. **Redeploy.** The web build must be redeployed before safetylens.in shows any of this.
