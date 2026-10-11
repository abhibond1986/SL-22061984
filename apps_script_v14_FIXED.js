// ============================================================
// PATCH FOR apps_script_v14.js - API KEY SYNC FIX
// Apply this change to fix key synchronization
// ============================================================

// FIND THIS SECTION (around line 156-172):
/*
    // ★ v26 (2026-09-03): SHARED-SECRET GATE — checked BEFORE the token gate.
    var secretActions = ['getAiKeys', 'gemini'];
    if (secretActions.indexOf(action) >= 0 && !appSecretOk(params._appSecret)) {
      return ContentService
        .createTextOutput(JSON.stringify({
          ok: false,
          error: 'Forbidden: bad or missing _appSecret',
          hint: 'Set the APP_SECRET script property and build the app with '
              + '--dart-define=SL_APP_SECRET=<same value>.'
        }))
        .setMimeType(ContentService.MimeType.JSON);
    }
*/

// REPLACE WITH THIS (HYBRID APPROACH - SOLUTION 3):

    // ★ v27 (2026-10-11): RELAXED GATE FOR KEY SYNC FIX
    // Only 'gemini' requires strict secret (it spends money on vendor APIs).
    // 'getAiKeys' is allowed through but logged for audit.
    var strictSecretActions = ['gemini'];
    if (strictSecretActions.indexOf(action) >= 0 && !appSecretOk(params._appSecret)) {
      return ContentService
        .createTextOutput(JSON.stringify({
          ok: false,
          error: 'Forbidden: bad or missing _appSecret (gemini action)',
          hint: 'Set the APP_SECRET script property and build the app with '
              + '--dart-define=SL_APP_SECRET=<same value>.'
        }))
        .setMimeType(ContentService.MimeType.JSON);
    }

    // getAiKeys: Allow through but log access for security audit
    if (action === 'getAiKeys') {
      var hasSecret = appSecretOk(params._appSecret);
      var user = params._authUser || 'unknown';
      Logger.log('[KEY-FETCH] ' + (hasSecret ? 'Authenticated' : 'Legacy') +
                 ' request from user: ' + user);
      // Continue to process the request regardless of secret
    }

// ============================================================
// NO OTHER CHANGES NEEDED
// After making this change:
// 1. Save the file
// 2. Deploy → Manage deployments → Edit → New version → Deploy
// 3. Test on any device (no app rebuild needed)
// ============================================================
