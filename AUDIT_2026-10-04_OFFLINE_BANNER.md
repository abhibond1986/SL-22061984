# Audit 2026-10-04: false "Offline" banner on mobile

## Report

On a phone (safetylens.in in mobile Safari), Reports → Log showed the banner "Offline — showing reports saved on this device" while the network was working.

## Investigation

**The server is healthy.** I queried the live Supabase project directly:

| Table | Size | Time |
|---|---|---|
| `incidents` | 47 rows, 170 KB | 2.4 s |
| `master_data` | 2 KB | 0.8 s |
| `knowledge_docs` | 2.7 MB per pull | 4.6 s |
| `app_users` | 700 KB | 0.9 s |

**The app's own sync works from a clean device.** `tools/sync_probe_test.dart` runs the real `SyncService.fullSync` against the live server. It returned `ok: true` in 8 s.

**The phone had in fact pulled the incidents.** It showed "47 of 47", which is the server's count. So the incident pull succeeded and the banner was raised by something that happened later.

**Root cause, which is a code defect.** Sync runs hold an exclusive lock (`_runExclusive`), and the lock had no escape.

- Three steps of `fullSync` had no timeout at all:
  - the user-list refresh;
  - the master-data refresh;
  - the 2.7 MB knowledge-base pull.
- Mobile Safari freezes a tab when the phone locks or the user switches apps. A request in flight at that moment may never resolve.
- That sync then never finishes, so it holds the lock for good.
- Every later sync, including the **Retry** button, queues behind it.
- The log's 45 s timer fires and shows "Offline" for the rest of the session. Only a page reload cleared it.

Desktop browsers rarely freeze tabs, which is why the banner appeared only on the phone.

There was a second weakness. The banner meant "every step of the sync succeeded", not "the server answered". A slow user list or KB download was therefore reported as being offline.

## Fix

### `lib/services/sync_service.dart`

- **Lock watchdog.** A locked run that takes longer than 75 s now fails with a `TimeoutException` and releases the lock, so a frozen request can no longer block later syncs or Retry.
- **Timeouts on secondary steps.** The users and master-data steps now have a 25 s timeout each and are **non-fatal**. The incident reconcile is what decides whether the sync succeeded.
- **Knowledge-base pull moved off the critical path.** It now runs in the background, at most every 10 minutes, with a 90 s cap. A full sync on the live server dropped from 8 s to about 4 s.
- **Storage failure is non-fatal.** If browser storage is full, the write of the last-sync time no longer fails a sync whose data has already landed.
- **Online/offline signal.** `lastServerContact` is set when the incidents table answers, and also on every realtime event. `serverReachedWithin(d)` reports whether that happened within a given time.
- **Error reason.** `lastSyncError` records why the last sync failed.

### `lib/screens/analytics/incident_log_tab.dart`

- **Banner decision.** The banner now looks at **server contact within the last 3 minutes**, not at whether every sync step succeeded.
- **Self-clearing.** A stale banner clears itself when a late sync or a realtime event proves the server is reachable.
- **Re-check on return.** The log syncs again automatically when the app returns to the foreground (`didChangeAppLifecycleState` → resumed), which is exactly when a phone's state is most likely stale.
- **Honest wording.** The banner now reads "Can't reach the server — showing reports saved on this device". A tooltip shows the actual error, so a persistent failure can be diagnosed.

### `lib/services/realtime_sync.dart`

- Realtime changes now update `SyncService.lastServerContact`.

## Verification

- `dart analyze lib`: 0 errors, 53 issues, which is the same baseline as before.
- `tools/sync_probe_test.dart`: **2/2 passed.**
  - The live `fullSync` returns `ok: true`, with server contact recorded and no error.
  - A deliberately hung run is cut off by the watchdog, and the run queued behind it completes about 2 s later. Before the fix it waited forever.
- Regressions: `log_render_test` 4/4 passed and `notification_render_test` 3/3 passed.
- **Not yet checked on the phone.** The web build has to be redeployed to safetylens.in first.

## Found during the investigation and not fixed here (needs your decision)

1. **Security: `app_users` is readable with the public anon key, including `password_hash` and `salt`.**
   - Anyone who opens the site can download the hashes for all 10,122 accounts.
   - **Recommended fix:**
     - Add an RLS policy, or a view, that exposes only the non-secret columns.
     - Move login verification to a server-side function (an RPC or Edge Function) so hashes never reach the client.
   - I have not changed this because it alters how login works.
2. **The knowledge base is far larger than the app can use.**
   - `knowledge_docs` has 13,019 rows (about 36 MB). The app only ever reads the newest 1,000 (the PostgREST cap).
   - None of the rows has a `client_id`, so they are never merged into the device's local KB.
   - At least one row stores raw .docx binary ("PK…") as its `content`.
   - It is worth a clean-up, and a server-side search instead of pulling the KB to every device.
3. **The user cache is capped at 1,000 of 10,122 accounts.** This is the known `usersTruncated` limit. Offline user lookups only see 1,000 names.
