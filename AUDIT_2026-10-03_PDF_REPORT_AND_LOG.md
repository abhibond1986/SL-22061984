# Audit: hazard/near-miss PDF report and cross-device incident log (2026-10-03)

Scope: the four requested changes (cross-device log, clearly marked hazard boxes, line of fire shown wherever present, share the PDF rather than text) plus the follow-up request to make the report layout professional. Verification was done by compiling the project with Flutter 3.19.6 / Dart 3.3.4 (the CI toolchain) and by rendering four sample reports through the real `PdfExport.generateIncidentReportBytes` code path. The rendered samples are in `audit_2026-10-03/`.

## Result

`dart analyze lib` reports **0 errors**. The 54 remaining infos/warnings were already there before this work and none are in the changed code paths. The render test passes, and all four sample reports fit on a single A4 page:

| Sample | What it exercises |
|---|---|
| `with_lof.pdf` | AI scan, 3 hazards: one with no location, one tiny box, one line of fire with a person in the path |
| `no_lof.pdf` | Same scan without the line-of-fire hazard ("none identified" state) |
| `not_analysed.pdf` | Scan that failed analysis: no rating, no hazards, no line-of-fire claim |
| `near_miss.pdf` | Near miss with no photo: summary, numbered corrective actions, GPS strip |

## 1. Incident log shows reports from all devices

Before this change, the log only showed what was stored on the current device, and reads from Supabase stopped at the server's row cap. Now `SupabaseService._fetchAllIncidentRows` reads the server in pages of 1000 rows and stops only when a page comes back empty, so a lower max-rows setting on the server can't cut the list short. Rows pulled from another device are stored as already synced, so they aren't uploaded back. The log tab syncs as soon as it opens, has pull-to-refresh, and shows a status strip at the top. The strip reads "Syncing", "N reports on this device not uploaded yet" with an Upload now button, "Offline" with Retry, or "Up to date with all devices · HH:mm". The time shown is the server sync time, not "now", when the sync was throttled. The plant filter no longer hides the user's own reports. On web, a report whose image upload failed keeps its inline image instead of losing it.

## 2. Hazard boxes are clearly marked

The photo grew from 132pt to 175pt tall, and each box is now painted as a white halo under a 2.4pt severity-coloured stroke, with heavier corner brackets. That combination reads over light and dark backgrounds and on a mono printer. Boxes smaller than 14pt are grown around their centre. The area outside the boxes is dimmed slightly (skipped when the boxes cover most of the frame). Number tags sit outside the box so they don't cover what they label, and use the same number and colour as the hazards table row. Small boxes also get an enlarged close-up crop next to the summary. A hazard the model could not place is marked "not marked on photo" in the table and counted in the caption, rather than left out without a word.

## 3. Line of fire shown wherever present; PDF is shared

Every located line of fire (up to three) is drawn as an arrow from the energy source to the person in its path, not just the single worst one. Under the photo, a strip lists each path ("3 conveyor belt -> worker"). It says "none identified in this photo" when there is none, and names any hazard the model called line of fire but couldn't locate. Line-of-fire rows carry a red LINE OF FIRE tag in the table, and the summary panel counts them. None of this is printed for a photo that was never analysed. Saying "no line of fire" about an image nobody looked at would be a false claim.

Share, WhatsApp and Email on the AI Scan result, Near Miss and Incident Detail screens now generate the PDF and share the file through `PdfExport.shareIncidentPdf`. On Android and iOS this opens the system share sheet with the PDF attached. WhatsApp shares carry no caption, because WhatsApp drops the attachment when text is sent with it. On web the browser's share sheet is used where it supports files. Otherwise the PDF is downloaded and a snackbar says so. Sharing an AI result that was never analysed is blocked, as before.

## 4. Layout redesign

The report now has a single navy masthead with the logo, report type and reference. A full-width rule in the severity colour runs under it, then a white title block with one RISK LEVEL badge. This replaces the two stacked colour bands. Section headings are tracked navy caps with a hairline to the margin. Incident details sit in one soft panel with hairline dividers. The evidence row is laid out as a one-row table, so the summary column takes the photo's height. That column holds the risk card (rating, matrix score with L×S factors, confidence), the summary, the close-ups and an at-a-glance row (hazards, marked on photo, line of fire, to verify). The hazards table uses horizontal hairlines, zebra rows, severity pills and number tags that match the photo. The sign-off block has three equal columns with room to sign by hand. Every page has a footer with the reference, date and "Page X of Y". All existing data rules are unchanged: the not-analysed and view caveats, the matrix re-derivation, and Latin-1-safe text.

## Defects found and fixed during the audit

The review turned up the following, all fixed and re-verified by rendering. The spotlight dim was painted over the line-of-fire arrow and darkened it, so it now sits underneath. Overlapping boxes got re-dimmed where they intersected (even-odd fill), which non-zero winding now prevents. Tag placement could throw on a very narrow image. A NaN/Infinity bounding box from a malformed model reply could corrupt the page, and is now skipped. The close-up row could run past the page edge with four wide crops, and now wraps. On web, decoding a very large photo for close-ups could freeze the tab, so close-ups are skipped above 3 MB there. The not-analysed notice printed its em dashes as empty boxes. An unrated report showed a green (LOW) badge and "AI confidence 0%", and now shows a grey NOT RATED and "not assessed". In the hazards table, the "not marked on photo" note was silently dropped by a pdf-package layout quirk with full-height table cells. The table now uses row decorations, and the photo row has a 1pt spacer at the bottom that absorbs the quirk. Earlier in the review: paging stopped on a short page, a throttled sync showed "now", web share success was read as "unavailable", and the download blob URL was revoked before the download started.

## Known limitations (accepted)

On web, if PDF generation takes long enough for the browser's user-activation window to expire, sharing falls back to a download. This is handled and reported to the user. The on-screen annotated image still draws one line of fire while the PDF draws up to three. A report with many long hazard rows can still run to a second page, and the page-2 header and footer carry over correctly. `pdfUrl` and the `matrix*` fields are not in Supabase's `_appToDb` allow-list, so they don't sync. The PDF re-derives the matrix from severity and confidence and marks the likelihood "(L est.)". None of this has been run on a physical device yet. The next CI build is the first device-level check of the share sheet.
