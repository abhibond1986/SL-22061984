# Audit 2026-10-04: Incident detail page was blank on desktop

## Symptom

Clicking a case in the Log opened a white page with only **Save** and **Mark as INVESTIGATING** in the middle of the screen. The app bar, photo, details, hazards and form were all missing.

## Cause

The bottom action bar is wrapped in `ContentWidth`, and `ContentWidth` is a `Center`. A `Center` grows to the full height its parent allows. Inside `Scaffold.bottomNavigationBar` that is the whole screen, so the bar filled the page and covered everything else, with its buttons centred vertically. The comment on `ContentWidth` even recommended using it in a `bottomNavigationBar`. No other screen puts it in that slot.

## Fix

- `ContentWidth` has a new option, `fillHeight` (default `true`). The other call sites are unchanged; the admin panel relies on the full-height behaviour. The detail screen's bar now passes `fillHeight: false`, and the widget's comment warns about this case.

## Details page improvements (as requested)

- **Layout.** Desktop and laptop (980 px or wider) use two columns, capped at `SLLayout.wide`:
  - Left column: the report itself. That is the title, severity, type and score, the photo, the facts card (date, plant, department, location, reporter, P.No, WSA cause, people), the description, the immediate action and the hazards found.
  - Right column: the work on the case. That is the Quick actions card, then the Mitigation & Closure form, then the timeline.
  - Phones keep a single column, with Quick actions straight after the facts card.
- **Quick actions card.** It shows the status, the action owner (amber "Unassigned" if nobody is set) and the target date (marked OVERDUE when past). Its buttons:
  - **Assign owner / Transfer** goes through `IncidentAssign`.
  - **Next stage** (Investigating, Action Taken, …, Close case) uses the same `_advanceStatus`, so it still requires an assignee.
  - **WhatsApp**, **Email** and **Download PDF** use the existing PDF share paths.
  - **Copy summary** copies the text summary to the clipboard.
  - **Reporter** and **Owner profile** open `EmployeeProfileScreen`.
  - Assign and next-stage buttons are hidden when the user may not act on the record or the case is closed.
- The app bar now reads "Incident report" plus the ID. The full title moved into the body, where it can wrap.

## Verification

- `dart analyze lib`: 0 errors, 53 issues, all pre-existing (no change).
- `tools/detail_render_test.dart` renders the real screen. The output is in `audit_2026-10-04/`: `detail_laptop.png` (1440×800) and `detail_phone.png` (400×1400). Square boxes in place of emoji come from the test font only.
- Not yet checked on safetylens.in. A web redeploy is needed.
