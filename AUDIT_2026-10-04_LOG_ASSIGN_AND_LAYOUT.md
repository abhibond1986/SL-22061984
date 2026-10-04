# Audit 2026-10-04: Incident Log (corrective-action assignment, screen space, row layout)

## 1. Corrective action needs an assignee

A new file, `lib/services/incident_assign.dart`, is now the single place where assignment happens. It checks permission (`PlantScope.canActOn`), applies the plant rule (`AssignScope`), opens the employee picker, saves `assignedTo` / `assignedToName` / `assignedAt` both locally and to Supabase, and writes the `incident_assigned` audit entry. The log row and the detail screen both call it, so they behave the same. The stored fields have not changed, so `AssignmentInbox` still notifies the assignee and no migration is needed.

In the Log, every row has an **Assign** button, which reads **Transfer** once someone is assigned. The row's "Status · Action owner" column shows the person's name, or **Unassigned** in amber.

On the incident detail screen, a case can no longer move past the first stage (to INVESTIGATING, ACTION TAKEN, VERIFIED or CLOSED) while nobody is assigned. Pressing "Mark as …" with no assignee opens the picker, titled "Assign who will implement the corrective action", with no "unassign" option. If the user cancels the picker, the status change is cancelled too. The field label now reads "Corrective action assigned to *".

## 2. Screen space and Ctrl+wheel zoom

**Cause of the space problem.** The filters, the summary and the sync strip sat in a fixed Column above an `Expanded` list. On a laptop, the app bar, tab bar, filters and bottom nav together left room for about one card, and scrolling moved only that small area.

**Fix.**

- The Log is now a single `CustomScrollView`, so the filters scroll away with the list. The list itself is still built lazily with `SliverList.builder`.
- When the viewport is shorter than 620 px, the filters start collapsed behind a **Filters (n)** toggle. Above that height they start open, and a **Hide filters** button is available.
- The severity, type, Mine and status chips now sit in one `Wrap` instead of two fixed rows, so a desktop width needs only one line for them.
- The tab bar on the Reports screen is 36 px tall instead of about 54 px.
- On a phone, the plant and department dropdowns used to overflow by about 230 px. They now fill their slot and shorten long names with an ellipsis (`isExpanded`).

**Cause of the Ctrl+wheel problem.** Flutter web calls `preventDefault()` on every `wheel` event, because it treats Ctrl+wheel as its own pinch gesture. That cancels the browser's page zoom.

**Fix.** `web/index.html` now registers a capture-phase, passive `wheel` listener on `window` before the engine loads. For Ctrl/Cmd+wheel only, it calls `stopImmediatePropagation()`, so the event never reaches Flutter, and the browser zooms normally. Plain scrolling is unaffected. One side effect: a Mac trackpad pinch now zooms the browser page instead of the app.

## 3. Row alignment and risk tint

- **Table layout** (content width of 1000 px or more): fixed columns for Incident, Plant · Date, Risk, Status · Action owner and Actions, under a header row. Button widths are fixed (Assign 96, PDF 64, Delete 80). The Delete slot is kept even when the user can't delete a row, so the buttons line up down the whole list.
- **Card layout** (phones and narrow windows): the details come first, then a divider, then a footer with the owner on the left and the buttons aligned right. The buttons drop below the owner when the card is too narrow for both. Previously the buttons were indented under the thumbnail.
- **Tint:** each row is lightly tinted by its 0–100 `riskScore`, using the `AdminMasterData.severityBands` bands: 80 and above is critical red, 60 and above is red, 35 and above is amber, anything lower is green. A solid 4 px bar in the same colour runs down the left edge. A record with no stored score uses its severity colour and shows "—" in place of the number.
- Flutter cannot paint rounded corners on a border whose sides differ in colour; it raised an assertion error in the first render. The row now uses a clipped `Material` with a uniform hairline border, plus a left border with no rounding. The ACTION TAKEN status colour (purple) was missing from `SL.textOn`, so its pill text is now mapped locally.

## Verification

- `dart analyze lib` on Flutter 3.19.6 found 0 errors. There are 53 issues, all pre-existing, down from the baseline of 54 (removed an unneeded `dart:ui` import).
- `tools/log_render_test.dart` builds the real `IncidentLogTab` with five mock incidents. The renders are in `audit_2026-10-04/`:
  - laptop 1280×640, light and dark
  - short laptop 1366×500 (filters collapsed automatically)
  - phone 400×860
- In the renders, the dropdown text appears as black blocks. That's because the test uses a placeholder font; the real app is not affected.
- Not yet checked on a device or on safetylens.in. Still to confirm on the live site: Ctrl+wheel zoom, and the picker opening from the Log and from "Mark as …".
