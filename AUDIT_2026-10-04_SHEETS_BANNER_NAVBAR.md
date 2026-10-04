# Audit 2026-10-04: "Saved & synced to Sheets" banner removed, bottom nav bar coloured

## 1. Why the "Saved & synced to Sheets" message appeared

This was a leftover from the app's earlier Google Sheets backend. In `lib/screens/ai_scan_tab.dart` the green strip "Saved & synced to Sheets · View Sheet →" was drawn whenever `_isSaved` was true. That flag is set once the report is stored **on the device**. The strip never checked whether the upload had worked, so it could claim a sync that hadn't happened. Its button opened an old hard-coded Google spreadsheet. The app now stores reports in Supabase, and the save dialog already shows the real upload result: "Synced to server", "Uploading…" or "Saved on this device only".

### What changed

- **AI Scan result.** The strip and its "View Sheet →" button are removed.
- **Save-success dialog.** The "View Sheet" button is removed, so "Done" now fills the row. The share buttons are unchanged.
- **"All hazards mitigated" sheet.** The "View in Sheets" button is removed, so "Done" now fills the row.
- **Unused code.** `_openSheetsLink()` and the hard-coded `_sheetUrl` were deleted.
- **Remaining wording that still mentioned Sheets:**
  - the help line now reads "Save: stores to device + server";
  - the feature tag now reads "☁️ Cloud sync";
  - the manual-sync toast (`msg.savedSheets`, EN and HI) now reads "N / M synced to server";
  - the contractor tooltip now reads "Sync to server".

## 2. Coloured bottom navigation bar

New `lib/widgets/nav_bar_style.dart` (`NavBarStyle`). The employee shell (`home_screen.dart`) and the contractor shell (`contractor_home_screen.dart`) both use it now, so the two bars cannot drift apart.

- **Light theme.** A brand-indigo gradient from `#5B67E0` to `#3B45B5`.
- **Dark theme.** A deep-indigo gradient from `#2B3275` to `#1A1E4A`.
- **Separator.** A thin white top hairline.
- **Unselected tabs.** White at 78% opacity.
- **Selected tab.** A white pill with an indigo icon and a bold white label.
- **Contrast.** White on `#4F5BD5` is about 5.6:1, and indigo on white is about 5.2:1. Both pass WCAG AA.
- **Unchanged.** Layout, tap areas, the 11 px labels and the Semantics.

Evidence (`tools/navbar_render_test.dart`, which uses the same NavBarStyle calls in the bar's layout):
`audit_2026-10-04/navbar_light_420.png`, `navbar_light_1000.png`, `navbar_dark_420.png`, `navbar_dark_1000.png`.

## Verification

- `dart analyze lib` gives 0 errors and 53 issues, the same as the baseline.
- `navbar_render_test` passed 4/4.
- A web redeploy is needed before the change appears on safetylens.in.

## 3. Revision: transparent light-blue nav bar (user request, same day)

The solid indigo band was replaced with translucent "frosted glass" in light blue. The only file changed is `lib/widgets/nav_bar_style.dart`. Both shells already use `extendBody: true` and the 16 px BackdropFilter blur, so no other code changed.

| | Light theme | Dark theme |
|---|---|---|
| Tint | sky-100 → sky-200 (`#E0F2FE` → `#BAE6FD`) at 50–62% opacity | sky-900 → sky-950 (`#0C4A6E` → `#082F49`) at 45–60% opacity |
| Top edge | White hairline | Sky hairline |
| Unselected tabs | Slate `#334155` | Sky-200 |
| Selected tab | White pill, sky-700 icon, bold sky-800 label | Sky-400 glass pill, white label |

The renders put coloured incident cards **under** the bar, as the real shells do, so the see-through effect is visible. Reds and greens show through as a blur, and the labels stay readable over them. Results: `dart analyze` 0 errors (53, same as the baseline); `navbar_render_test` 4/4; PNGs `audit_2026-10-04/navbar_{light,dark}_{420,1000}.png` regenerated.
