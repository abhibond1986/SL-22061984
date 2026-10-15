# MAMR — Design Specification (for approval)

SAIL Safety Lens · Draft 1 · 15 Oct 2026
Source: hand-written requirement sheet + `ASP AREA responsibility (2).xlsx`

---

## 1. What we are building

MAMR replaces the AI Hazard Scan tab. Every plant gets an area-responsibility register (the Excel you shared). When anyone photographs a hazard, they first say *which area* it is in. The app then knows who owns that area, assigns the observation to that person automatically, and tracks it as **Pending** until it is **Complied**. The photo is still analysed by the same AI pipeline. The PDF looks the same as today, with one new MAMR block.

MAMR stands for **"My Area My Responsibility"** (confirmed 15 Oct 2026). The full form appears on the tab header, the Home card and the PDF block title.

The scope line at the top of the ASP sheet lists six areas of work. These become the **MAMR observation categories**, so the reporter picks one when filing:

| Category | |
|---|---|
| Line of Fire identification | Housekeeping |
| Safety Signage & Display | Painting & Identification Marking |
| Safety Incident remediation | Any other safety improvement point |

### Decisions you have already made

| Question | Your answer |
|---|---|
| Home screen card | **Both.** Your own area(s) at the top, then the full plant list below. |
| SED role | **Plant-scoped MAMR manager.** The super admin marks a user as SED. That user can then manage MAMR for their own plant only. |
| AI Hazard Scan tab | **Replace it with MAMR.** Same photo analysis. The PDF gains an MAMR block and is otherwise unchanged. |
| Process | **This spec first, then the build.** |

---

## 2. Roles and permissions

There is currently no plant-level manager role in the app. Users are either admins, who see every plant, or ordinary users, who are locked to their own plant. SED is a new flag on top of an ordinary user. It is not a full admin. It unlocks MAMR management for that user's own plant and nothing else.

| Action | User | Responsible person | SED (own plant) | Super admin |
|---|---|---|---|---|
| See own area(s) and plant area list on Home | ✓ | ✓ | ✓ | ✓ (all plants) |
| File an MAMR observation (any area of own plant) | ✓ | ✓ | ✓ | ✓ |
| See MAMR statistics in Reports | own plant | own plant | own plant | all plants |
| Update an observation and mark it **Complied** | — | ✓ (own areas) | ✓ | ✓ |
| Add a department, upload or replace the area Excel, edit or reassign an area | — | — | ✓ | ✓ |
| Grant or revoke the SED role | — | — | — | ✓ |

Today, the incident screen only lets someone act on a case if they belong to the same plant. Being the assignee is not enough on its own. The MAMR rule will be explicit: **the responsible person of the area can close it**, and so can the plant's SED and the super admin.

---

## 3. Data model

### 3.1 Area register — one record per plant

The register will be stored the same way the app already stores plants, departments and statuses. That is the `master_data` table, under one key per plant, for example `mamr_areas_ASP`. This choice means the existing sync, offline cache and realtime refresh all work for MAMR with no new code. A plant's register is small: ASP has 32 rows.

Each plant's record contains:

```
{
  plant: "ASP",
  departments: ["SMS", "MRD", "CCS", ...],      // includes depts added by hand with no areas yet
  areas: [
    { id: "ASP-001", sn: 1, dept: "SMS",
      area: "Pit Side, LF #1, VAD, MS Bay",
      persons: [ { name: "CHAKRADHAR SAHOO", designation: "DGM (SMS & CCS)",
                   mobile: "9434798958", username: "<matched app user or null>" } ],
      active: true }
    ...
  ],
  updatedBy, updatedAt, sourceFile
}
```

Each area's `id` stays fixed for the life of the area. Re-uploading a corrected Excel updates the existing areas instead of creating new ones. Matching uses department plus area name, so links from past observations stay valid.

The handwritten "Add new department → Department name" flow adds a name to `departments`. An SED can create a department before any of its areas exist, and then add areas to it by hand or through the next upload.

### 3.2 SED flag on users

A new column, `app_users.is_sed boolean default false`, is added to `app_users`. It also has to be added to the app's field mapping (`_userAppToDb`); otherwise the value is silently dropped when it syncs. An SED's plant is simply their own plant on their user record.

### 3.3 New fields on each observation

Each field below needs **both** a column added to the Supabase `incidents` table **and** an entry in the app's `_appToDb` mapping. If one column is missing, Supabase rejects the whole row, and all syncing stops — not just MAMR. The SQL will be delivered as a single migration file for you to run before the new build goes out.

| Field | Meaning |
|---|---|
| `type = 'MAMR'` | Replaces `'AI_SCAN'` for new reports. Old AI-scan reports are kept and still counted. |
| `mamrAreaId` | Link to the area register |
| `mamrDept`, `mamrArea` | Department/shop and section/area, copied at filing time |
| `mamrCategory` | One of the six scope categories |
| `mamrResponsible` | The responsible person(s) at the time of filing: name, designation, mobile, username |

The responsible person is **copied** onto the observation. If an SED later reassigns an area, existing observations keep the person who was responsible when they were filed. Only new observations go to the new person. This is deliberate, so that history is never rewritten.

`dept` (department) is currently the **reporter's** own department. For MAMR, I recommend setting `dept` to the **area's** department and keeping the reporter's department in a new field, `reporterDept`. The plant-wise and department-wise analytics would then show where the hazard *is*, not who happened to see it. *(Please confirm — see §9.)*

### 3.4 Pending vs Complied

There will be no second status system. The admin's existing workflow (OPEN → INVESTIGATING → ACTION TAKEN → VERIFIED → CLOSED, or whatever stages the admin has configured) is reused:

- **Complied** means the last stage.
- **Pending** means any earlier stage.

For MAMR reports, the labels shown on screen will read "Pending" and "Complied".

Two places in the current scan screen ignore the admin's workflow and must be fixed as part of this work:

- New reports are always saved as `'OPEN'` (`ai_scan_tab.dart:2559`).
- A report jumps straight to `'CLOSED'` once every hazard is mitigated (`:2429`).

If these are left as they are, a renamed workflow would put MAMR counts in the wrong bucket.

---

## 4. Uploading the area Excel

The upload reuses the app's existing spreadsheet reader, the same one behind Bulk User Import. It reads `.xlsx`, `.csv`, and `.xls` (`.xls` via the backend). It finds the header row on its own, so the merged scope title in row 1 of the ASP sheet is skipped without any extra handling.

**Header matching.** Each column is recognised by a list of accepted names, so small spelling differences don't matter. The required columns are Dept/Shop, Section/Area, Responsible person and Mobile. SN, Plant/Unit and Designation are optional; a missing plant defaults to the SED's own plant.

**Cleaning rules.** Each of these comes from a real row in the ASP file:

| Found in the ASP file | Rule |
|---|---|
| Row 31 has plant `"ASP "` (trailing space) | Trim the value and match it to the plant master by code. A row for another plant is rejected for an SED; a super admin can import any plant. |
| Rows 10 and 15 hold two people in one cell (`"JAYDEEP DUTTA\nRAVI ANAND"`, with two designations and two mobiles) | Split on line breaks into two responsible persons for the same area. Both see the observation and either can mark it Complied. If the counts don't line up, show a warning. |
| Row 12 mobile is `"\t9434798917"`; row 32 name is `"\tSUMAN KUMAR JHA"` | Strip tabs and stray spaces. Store the mobile as its **last 10 digits**. |
| Rows 33–57 have an SN but are otherwise empty | Ignore them silently. |
| Two different people are both called "AMIT KUMAR" (rows 9 and 30) | Match people by **mobile, never by name**. |

**Linking a person to an app user.** Each responsible person is looked up in `app_users` using the last 10 digits of their mobile. This is needed because the bulk user import stores mobiles with the country code (`91…`) and self-registered users type them however they like.

- **Matched:** the observation is assigned to that user automatically and reaches their My Assignments card and notification bell.
- **Not matched:** the area is still filed and counted, and it shows a "not on app" badge. The SED can link a user by hand using the existing user picker.

**Preview before saving.** Nothing is written until the SED confirms. The preview shows:

- the number of rows read and the number ignored;
- the departments found;
- people matched or not matched to app users;
- all warnings.

The SED then chooses either **Merge** (update existing areas and add new ones) or **Replace** (areas missing from the file are marked inactive, not deleted, so old observations still resolve). Every upload is recorded in the Audit Log.

A **"Download template"** button provides a blank sheet with the exact headers.

---

## 5. Screens

### 5.1 Home — "My MAMR Area" card (requirement ①)

This card sits directly under the hero banner, above My Assignments.

- **Top section, "My Area":** every area where the logged-in user is a responsible person. Each row shows the department and area, Pending and Complied counts, and a **Report** button. Report opens the MAMR tab with that area already selected.
- **Below, "All areas — ASP":** a collapsible, searchable list of the plant's register, grouped by department. Each row shows the area, the responsible person and their designation, and a pending count. A tap on the mobile number opens the dialler.
- If the user owns no area, the top section reads "No area is assigned to you" and only the plant list is shown.
- An SED also sees a **Manage MAMR** shortcut on this card.

### 5.2 MAMR tab (requirement ③)

The MAMR tab takes the AI Scan tab's slot in the bottom bar, so the order of the other tabs is unchanged. The label "AI Scan" becomes "MAMR" in both English and Hindi, and the icon changes too.

The flow:

1. **Area.** Pick the department, then the section/area. Both lists come from the plant's register. A card then shows the responsible person, designation and mobile, so the reporter can see who will receive it.
2. **Category.** Pick one of the six scope chips.
3. **Photo.** Take a photo or upload one, exactly as today. The same AI analysis runs, in the background as it does now, along with GPS and the location text.
4. **Review.** The hazard table, risk matrix and summary are unchanged from today's results page.
5. **Save.** The observation is saved with its MAMR area and assigned to the responsible person. They are notified, and the PDF is generated.

Every existing safeguard on the scan screen stays in place. A failed analysis can still not be filed. An empty hazard list still goes through the corroboration check. The line-of-fire overlay, the verify-on-site class and the 5×5 matrix all work as they do today.

An observation **cannot be saved without an area.** A plant with no register yet shows: "MAMR areas not set up for your plant — contact your SED".

**Contractor mode** currently opens the AI Scan tab. It will open MAMR instead, with a plant picker first, because contractors have no plant on file.

### 5.3 Reports — new "MAMR" sub-tab (requirement ②)

This is added alongside Overview / Log / Analysis / Plant Wise. It has:

- **From and To date pickers.** These are real calendar pickers, not just the fixed "30 days / 90 days" options the Log tab has today. The range defaults to the current month.
- **Headline tiles:** observations recorded, Complied, Pending, and Complied %.
- **Table by department, then area:** area, responsible person, recorded, complied, pending, and the oldest pending item in days. A tap on any row opens those observations in the Log.
- **Category split:** a count for each of the six scope categories.
- **Export** of the table to Excel or PDF.

Each role sees its own scope. An ordinary user sees their plant. An SED sees their plant. The super admin sees all plants and can filter by plant.

### 5.4 SED / Admin — "MAMR Areas" module

This is a new module in the admin drawer. It is the only admin module an SED can see. An SED opens it from Home → Manage MAMR.

It provides:

- the department list, with **+ Add new department → Department name**;
- **Upload Excel** (§4) and **Download template**;
- the area list, grouped by department, with edit, deactivate and **Reassign** for each area. Reassign opens the user picker, which is limited to the plant's users.
- a counter of people not linked to app users, with a "fix" link.

The super admin also gets an **SED** toggle on each user in User Management.

### 5.5 PDF report

Everything in the current PDF stays where it is. One block is added directly under the existing details grid:

```
┌─ MAMR — MY AREA MY RESPONSIBILITY ───────────────────────────────────┐
│ Dept./Shop: SMS            Section/Area: Pit Side, LF #1, VAD, MS Bay │
│ Responsible: CHAKRADHAR SAHOO, DGM (SMS & CCS) · 94347 98958          │
│ Category: Housekeeping     Status: Pending  (Complied on: —)          │
└──────────────────────────────────────────────────────────────────────┘
```

When a report is Complied, the PDF also shows the corrective action, the person who closed it and the date.

---

## 6. What stays the same

The following are untouched:

- the AI pipeline: models, prompts, validation, de-duplication and the risk matrix;
- Near Miss;
- SOP Scan;
- Ask AI;
- the existing Reports sub-tabs;
- the PDF layout apart from the one new block.

Old AI-scan reports remain visible everywhere. They simply have no area attached.

---

## 7. Build plan

| Phase | Work | Main files |
|---|---|---|
| 1. Data | SQL migration (`incidents` columns, `app_users.is_sed`); register model + service; mobile normaliser; field mappings | new `services/mamr_service.dart`, `supabase_service.dart`, `migration_mamr.sql` |
| 2. Roles | SED flag, `canManageMamr`, "responsible person can close" rule | `plant_scope.dart`, `incident_detail_screen.dart`, User Management in `admin_screen.dart` |
| 3. Register admin | MAMR Areas module, add department, upload + preview, reassign | new `screens/mamr_admin_screen.dart`, reuse `tabular_reader.dart` |
| 4. MAMR tab | Area + category step before the photo, auto-assign on save, fix the hard-coded OPEN/CLOSED | `ai_scan_tab.dart` (renamed flow), `home_screen.dart`, `app_tabs.dart`, `i18n.dart`, `contractor_home_screen.dart` |
| 5. Home card | My Area + plant list | new `widgets/mamr_area_card.dart`, `home_tab.dart` |
| 6. Reports | MAMR sub-tab with From–To | new `screens/analytics/mamr_stats_tab.dart`, `reports_tab.dart` |
| 7. PDF | MAMR block | `pdf_export.dart` |
| 8. Verify | Analyzer baseline diff; unit tests for the Excel cleaner, run against your ASP file; mobile matching; Pending/Complied counts with a renamed workflow | `tools/` |

The ASP register will be loaded from your Excel as the first real data set.

**Things you will need to do yourself after the build:**

1. Run `migration_mamr.sql` in Supabase **before** installing the new build.
2. Mark the ASP SED user(s) as SED.
3. Rebuild and redeploy the app.

No Apps Script redeploy is needed unless you still sync incidents to Google Sheets. In that case, the new columns also have to be added to the sheet.

---

## 8. Risks I am designing around

- **One missing Supabase column stops all syncing,** not just MAMR. The migration therefore ships with the build, and the app writes MAMR fields only after confirming the columns exist.
- **Mobile mismatches** (with or without the country code, typing errors) would leave people unlinked. The last-10-digits match handles the first case, and the preview shows every unmatched person so the SED can fix them before saving.
- **An area renamed in a later Excel** would look like a brand-new area. The preview flags near-duplicates, for example a different area name under the same department with the same mobile, so the SED can map it to the old area instead.

---

## 9. Decisions (answered 15 Oct 2026)

| Question | Answer | What the build does |
|---|---|---|
| MAMR full form | My Area My Responsibility | Shown on the tab header, the Home card, Reports and the PDF block title. |
| Department on the observation | (default taken) | `dept` = the area's department; the reporter's department is kept in `reporterDept`. |
| Who may mark Complied | The responsible person | Only a person on the observation's responsible list, or its current assignee, can move it to the last stage. The SED or super admin can do it only when the area has nobody responsible. |
| Automatic target date | Yes | Set on save from the worst severity: Critical 1 day, High 2, Medium 7, Low 15 (others 7). Reports shows Overdue separately from Pending. |
| Mobile in the PDF | No: name and designation only, plus the MAMR area | The PDF block shows Deptt./Shop, MAMR Area, Category, Compliance, Target Date, Responsible Person (name, designation), Corrective Action and Closed By. Mobiles appear only inside the app. |

## 10. Build notes: where the build differs from this draft

- **SED role storage.** The SED list is stored in `master_data` under the key `mamr_sed`, not in a new `app_users.is_sed` column. The reason: user writes in the app have no tolerance for a missing column. If the new column existed in the app but the migration had not been run, every registration, password change and bulk import would fail.
- **Observation type.** MAMR observations are saved with `type = 'AI_SCAN'` and are identified by `mamrAreaId`. About 15 places in the app (analytics filters, the PDF, the AI audit, the incident log) look for that type. Keeping it means old AI-scan history and new MAMR rows stay in one series. The app shows these rows as "MAMR" or "MAMR / AI Scan".
- **Migration and sync.** `migration_mamr.sql` adds six columns to `incidents`. Run it before installing the build. If the build runs before the migration, observations still sync, but without their MAMR fields, because the app drops columns the server does not have.
- **New tests.** `tools/mamr_core_test.dart` runs against the real ASP sheet. All 69 checks pass.
- **Observation category removed (15 Oct 2026, at the user's request).** The MAMR tab no longer asks for one of the six categories. The PDF block shows Target Date in its place, and Reports no longer has a "By category" panel. Rows saved before the change keep the category they were given.
- **Layout of Reports → MAMR (15 Oct 2026).** The page reads from the top in this order: *Your area* (a compliance ring for each area you are responsible for, plus the observations waiting for your action), then *Other areas* (pending first; areas with no observations are folded into a single line), then *Entire plant* (a large ring, the headline figures, and departments ranked by pending).
- **Home card (15 Oct 2026).** It shows your area with Done, Pending and Overdue, plus the Near Misses still open in that shop. If you are not responsible for any area, it shows your own shop instead. Below that come the observations you reported and the full list of areas.
- **Shared visuals.** The ring, the bar and the plant-layout background are all in `lib/widgets/mamr_visuals.dart`. Colours are fixed: green means complied, amber means pending, red means overdue.
