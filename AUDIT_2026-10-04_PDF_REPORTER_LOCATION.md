# Audit 2026-10-04: PDF "Reported by", lighter masthead, GPS location

## 1. Wrong reporter in the PDF: verified and fixed

**What the report showed.** Incident `1791107789679` ("Unsecured LPG cylinder on cart", DSP) printed **Reported by: System Admin, P.No. ADMIN001**.

**What the server holds.** The live Supabase row is correct:

- `reported_by = Ravi Shankar`
- `reported_by_pno = D001685`

The data was right. The PDF was wrong.

**Root cause.** The incident detail screen's **PDF** and **Share** buttons passed the *logged-in viewer* (`LocalDB.getCurrentUser()`) as `reporterName`/`reporterPno`. Any admin who opened someone else's case therefore printed their own name as the reporter, in both the "Reported by" cell and the sign-off block.

**Fix.**

- **`PdfExport.generateIncidentReportBytes`.** It now uses the incident's own `reportedBy` / `reportedByPno` whenever they are present. The caller's values are only a fallback for old records that lack them. This fixes every PDF and share path in one place: detail screen, log, AI scan, near miss and consolidated reports.
- **`incident_detail_screen.dart`.** Both calls now pass the incident's reporter explicitly as well.

## 2. Masthead colour, "a little less dark"

The band and the RISK LEVEL badge now use new `_mastCol()` shades, one step lighter than before. Body text keeps the darker severity ink.

| Severity | Before | After | Contrast with white |
|---|---|---|---|
| CRITICAL | `#8E1B1B` | `#C62828` | 5.6:1 |
| HIGH | `#C62828` | `#E04848` | about 4.0:1 |
| MEDIUM | `#B45309` | `#D07A12` | about 3.1:1 |
| LOW | `#2E7D32` | `#43A047` | about 3.1:1 |

All four are at or above 3:1, which is the floor for the large bold text the band carries. The small secondary text on the band was moved closer to white so it stays legible.

## 3. Location from the photo

**Before:**

- GPS was read from the photo's EXIF **only for gallery picks**. A camera capture went straight to device GPS.
- AI scans always saved the placeholder `"AI scan result — <section>"` as their Location, even when a GPS place name had been captured.

**Now:**

- **EXIF first for every photo** (`_captureLocationSmart`). On the web build, a phone-camera photo often carries GPS. Device GPS stays as the fallback.
- **Save.** The saved `location` is the captured place name. The placeholder is used only when there is none.
- **PDF `_locationText()`.** A placeholder or blank location is replaced with, in order:
  1. the GPS place name;
  2. otherwise the coordinates;
  3. otherwise the detected section;
  4. otherwise "Not recorded".
- **Where it prints.** The location appears in the details grid and the title sub-line. The existing **GPS LOCATION** strip (place, ±accuracy, time, Google Maps link) prints whenever coordinates exist.

**This particular incident has no GPS.** The server row has `latitude`/`longitude` = null, and the stored photo has no EXIF at all (it was re-encoded on upload). There is nothing to recover. Its PDF now says "Not recorded" instead of the placeholder.

Mobile browsers (iOS Safari especially) can also strip GPS from photos they hand to a web page. Device GPS then needs the browser's location permission.

## Verification

- `dart analyze lib` gives 0 errors and 53 issues, the same as the baseline.
- `tools/pdf_reporter_location_test.dart` passed 1/1.
  - It pulls the **live** incident and generates the PDF with the viewer set to "System Admin / ADMIN001", which reproduces the bug.
  - The output names **Ravi Shankar / D001685** in the grid and the sign-off, and "System Admin" appears 0 times.
  - A GPS variant prints the place in Location, in the sub-line and in the GPS strip.
  - The page count is 2, the same as the original.
- Evidence in `audit_2026-10-04/`:
  - `pdf_ravi_shankar_fixed.pdf` and `pdf_ravi_shankar_p1.png`;
  - `pdf_sample_with_gps.pdf` and `pdf_gps_critical_p1.png`;
  - `pdf_mastheads.png` (all four severities).
- A web redeploy is needed for safetylens.in.
