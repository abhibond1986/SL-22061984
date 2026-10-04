# Audit 2026-10-04: notification bell for case assignments

## Request

> "also add a bell icon with notification icon in the top right corner so that if any incident is assign to a user a notification is generated"

## What was built

| File | Change |
|---|---|
| `lib/services/assignment_notifications.dart` | **New.** App-wide notification state (`AssignmentNotifications.state`, a ValueNotifier), with `refresh()`, `markRead()` and `markAllRead()`. |
| `lib/widgets/notification_bell.dart` | **New.** `NotificationBell` (bell icon, unread badge and arrival toast), `showNotificationPanel()` and `NotificationPanel`. |
| `lib/widgets/universal_app_bar.dart` | The bell is inserted in the top-right row, just before the user avatar, so it appears on every screen that uses the universal app bar (Home, AI Scan, Near-miss, Reports, Chat, Doc Q&A, SOP Scan). |
| `lib/services/incident_assign.dart` | After an assignment is saved, it calls `AssignmentNotifications.refresh()`. Local saves do not bump the realtime revision, so without this the bell would wait for the next poll. |
| `tools/notification_render_test.dart` | **New.** Harness with 1 logic test and 2 render tests, all passing. |

## How it behaves

The bell is an outline icon when nothing is unread. When something is unread it turns amber and shows a red count badge (capped at 99+).

A user gets a notification in two cases:

- **Case assigned to you.** Any open incident whose `assignedTo` is your username or P.no. Re-assigning a case to you notifies you again.
- **Your report is being investigated.** An incident you reported (matched on P.no) that now has an investigator. This closes the loop for the reporter.

Tapping the bell opens the notification panel:

- On desktop or laptop (600 px or wider) it is a 400 px drop-down anchored under the bell.
- On a phone it is a bottom sheet.
- Each row shows the kind, the title, severity, an OVERDUE chip when the target date has passed, the plant, and the time since assignment.
- Unread rows are tinted and carry a red dot.
- The header has "N new" and **Mark all read**.

Tapping a row marks it read and opens the incident detail page.

**Toast.** When a new assignment arrives while the app is open, a SnackBar shows "New case assigned to you: …" with an OPEN action. With several arrivals it reads "N new case assignments" with a VIEW action.

Two rules keep the toast from becoming noise:

- Opening the app does not toast the existing backlog; the badge shows that.
- The toast is shown once even though several tabs keep app bars mounted. A static generation counter guards it, and only the bell on screen raises it.

**Lifecycle.** A notification disappears by itself when the case is closed (per the admin's status ladder) or reassigned to someone else. This is because the list is derived from the incidents (AssignmentInbox) and not stored separately.

## Design decisions

- **Separate read state.** Read state is stored in `notif_read_<username>`. The dashboard's "NEW" marker uses `assignment_seen_<username>` and marks everything seen as soon as Home renders. Sharing that key would have emptied the bell before the user ever looked at it. Read keys for items that no longer exist are pruned, so the set does not grow without limit.
- **Per account.** Shared plant terminals keep each user's unread items separate.
- **Refresh triggers:**
  - `RealtimeSync.incidentsRevision`, which fires for an assignment made on another device and after a full sync;
  - `AdminMasterData.revision`, which fires when the status ladder changes;
  - right after a local assignment;
  - a 60 s poll, as a fallback when realtime is disconnected.
  - Bursts of events are coalesced into one reload after 300 ms.
- **No database change.** No migration and no new table are needed, and it works offline.

## Verification

- `dart analyze lib`: 0 errors and 53 issues, which is the same pre-existing baseline. The new files produce no issues.
- `flutter test test/notification_render_test.dart`: **3/3 passed.** The logic test checks that:
  - there are 3 notifications and the closed case is excluded;
  - the first load raises no toast;
  - `markRead` reduces the count;
  - a new assignment arrives as an arrival and bumps the generation;
  - a reassign-away removes the item;
  - `markAllRead` brings the count to 0 and persists in `notif_read_*`;
  - the dashboard seen-set is untouched.
- Evidence in `audit_2026-10-04/`:
  - `bell_header_laptop.png`: the badge in the header;
  - `bell_panel_laptop.png`, `bell_panel_dark.png` and `bell_panel_phone.png`: the panel on laptop, in dark mode, and on phone;
  - `bell_panel_empty.png`: the "You're all caught up" state.

## Limits and follow-ups

1. **In-app only.** Notifications appear while the app (or the web tab) is open. A push to a phone whose app is closed needs `NotificationService` (FCM) to be initialised, device tokens to be stored per user, and a server trigger (a Supabase webhook or Edge Function on `incidents.assigned_to`) that sends the push. This can be added as a next step.
2. **No "assigned by" name.** The incident has no `assignedBy` column, so notifications do not name the supervisor who made the assignment. Adding one needs a DB migration.
3. **Redeploy.** The web build must be redeployed before safetylens.in shows the bell.
