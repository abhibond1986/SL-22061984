/**
 * ═══════════════════════════════════════════════════════════════════════
 * SAIL SAFETY LENS — "Nara Router" PROXY PROJECT — MAIN HANDLER
 * ═══════════════════════════════════════════════════════════════════════
 *
 * ⚠ READ THIS FIRST — WHICH PROJECT DOES THIS FILE BELONG TO?
 *
 * This file is written for the STANDALONE "Nara Router" Apps Script project
 * (deployment AKfycbx0CUXs6VZg-nIzTV039ThJL6ywa2rzK3xyIdHEmeC5-... as of
 * 2026-08-19; it was previously AKfycbz7rcn6yIr_-turaxr...).
 *
 * It is NOT the app's main backend. The Safety Lens app has a DIFFERENT
 * Apps Script deployment hardcoded in lib/services/sync_service.dart:
 *   https://script.google.com/macros/s/AKfycbzDiT4OSvlDUxvcM9DYJ_-SiB1Hy...
 * That other project is what serves incidents, users, and getMasterData.
 *
 * DO NOT paste this project's URL into the app's backend/sync URL setting.
 * Doing so points the whole app at a project that has no Incidents sheet,
 * no user records and no master data, and all sync will break.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THIS IS THE CHOSEN SETUP (2026-08-19) — standalone proxy
 * ═══════════════════════════════════════════════════════════════════════
 * The app was updated to match. Dart no longer reuses the sync backend URL for
 * vision calls; it has a dedicated preference and a compiled-in default:
 *
 *     NaraVision.kPrefsProxyUrl   'nara_proxy_url'   (admin override)
 *     NaraVision.defaultProxyUrl  this deployment's /exec URL
 *
 * ⚠ IF YOU REDEPLOY TO A NEW DEPLOYMENT ID, the compiled default goes stale.
 * Either edit `defaultProxyUrl` in lib/services/nara_vision.dart and rebuild, or
 * have each admin paste the new URL into Admin → System Health → NaraRouter →
 * "Apps Script AI proxy URL". The override is per-device, so the rebuild is the
 * only fix that reaches everyone. Prefer updating an EXISTING deployment to a new
 * version, which keeps the URL stable and needs no app change at all.
 *
 * The alternative (merging NaraVisionProxy.gs into the main backend and adding
 * `if (action === 'analyzeImageNara') …` to its doPost) still works and is
 * simpler to operate, but was declined in favour of keeping the AI proxy
 * isolated from the sync backend. If you ever merge, DELETE handleGetMasterData_
 * below first — see the note on that function.
 *
 * @author SAIL Safety Lens Team
 * @version 2.1
 * @date 2026-08-19
 */

/**
 * Main POST handler — entry point for requests routed to THIS project.
 */
function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const action = data.action;

    Logger.log('Received action: ' + action);

    // ═══════════════════════════════════════════════════════════════════
    // NARAROUTER VISION PROXY (from NaraVisionProxy.gs)
    //
    // The reason this project exists. router.bynara.id sends no CORS
    // headers, so a browser blocks its replies and NaraRouter is unusable
    // from Flutter web. UrlFetchApp is server-side and has no such limit.
    // ═══════════════════════════════════════════════════════════════════
    if (action === 'analyzeImageNara') return handleAnalyzeImageNara_(data);

    // ═══════════════════════════════════════════════════════════════════
    // KEY DISTRIBUTION — 'getMasterData', not 'syncApiKeys'
    //
    // NAME IS LOAD-BEARING. AdminMasterData.syncFromBackend() in the Flutter
    // app pulls via SyncService.pullMasterData(), which posts exactly
    // {action: 'getMasterData'} and reads parsed['data']. There is no
    // 'syncApiKeys' caller anywhere in the app, so a handler by that name is
    // dead code that will never run — an earlier draft of this file had one.
    //
    // ⚠ IN THIS PROJECT IT IS EFFECTIVELY DEAD CODE, and knowing why matters.
    // SyncService posts getMasterData to the MAIN backend, never here — that is
    // the whole point of the split. So keys placed in THIS project's Script
    // Properties reach web scans (server-side, via analyzeImageNara) but never
    // reach a phone. Mobile calls Nara directly and needs a local key, which it
    // can only get from the MAIN backend's getMasterData.
    //
    // Net effect: NARA_API_KEY / NARA_MODEL must be set in BOTH projects, with
    // the same model string. Set it only here and every phone silently skips
    // Tier 1b; set it only there and web silently skips it.
    //
    // Kept anyway as a deliberate escape hatch: if the proxy URL is ever pointed
    // at this project for sync in an emergency, it answers with the right shape
    // instead of "Unknown action". If you MERGE this file into the main backend,
    // DELETE this handler first — that project has its own getMasterData
    // returning plants/departments/WSA causes as well as keys, and two functions
    // with one name means the last loaded silently wins, taking the master lists
    // down with it.
    // ═══════════════════════════════════════════════════════════════════
    if (action === 'getMasterData') return handleGetMasterData_(data);

    // ═══════════════════════════════════════════════════════════════════
    // DOCUMENT Q&A — requires DocQaProxy.gs in this project.
    //
    // Answers a question using ONLY extracts from a document the user
    // uploaded, which the PaddleOCR service (ocr_service/) has already read.
    // Kept server-side because the Gemini key must never reach the browser.
    // If DocQaProxy.gs is missing, this line throws a ReferenceError that the
    // catch below reports as a generic error — so add the file, or comment
    // this out, rather than leaving a half-installed feature.
    // ═══════════════════════════════════════════════════════════════════
    if (action === 'answerFromDocument') return handleAnswerFromDocument_(data);

    // ═══════════════════════════════════════════════════════════════════
    // ALERT SYSTEM — only available if AlertSystem.gs is ALSO in this project
    //
    // Left commented out on purpose. As of 2026-08-19 this project contains
    // only Main.gs and NaraVisionProxy.gs; AlertSystem.gs lives on disk and
    // in the main backend. Uncommenting these without adding the file would
    // make each action throw a ReferenceError that the catch below reports as
    // a generic error — harder to diagnose than the honest "Unknown action".
    // ═══════════════════════════════════════════════════════════════════
    // if (action === 'syncAlertRules')   return handleSyncAlertRules_(data);
    // if (action === 'fireAlert')        return handleFireAlert_(data);
    // if (action === 'evaluateAndAlert') return handleEvaluateAndAlert_(data);
    // if (action === 'getAlertHistory')  return handleGetAlertHistory_(data);

    // ═══════════════════════════════════════════════════════════════════
    // UNKNOWN ACTION
    // ═══════════════════════════════════════════════════════════════════
    Logger.log('Unknown action: ' + action);
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: 'Unknown action: ' + action,
      hint: 'This is the Nara Router proxy project, not the main Safety Lens '
          + 'backend. Sync actions belong to the other deployment.',
      availableActions: ['analyzeImageNara', 'getMasterData', 'answerFromDocument']
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    Logger.log('Error in doPost: ' + err.toString());
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: err.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

/**
 * Serve the AI provider keys held in this project's Script Properties.
 *
 * FIELD NAMES ARE A CONTRACT with AdminMasterData.syncFromBackend(). They were
 * read off that function rather than invented:
 *
 *   naraApiKey  — written to prefs only if it startsWith('sk-nry-'). The app
 *                 prefix-checks because this sync runs on EVERY launch, so a
 *                 wrong-provider key here would be re-pushed to every device
 *                 forever and add a dead 20s attempt to every failing scan.
 *   naraModel   — NOT 'naraDefaultModel'. The app ignores any other spelling,
 *                 and also rejects any value that is not one of the five IDs
 *                 in NaraVision.availableModels (listed below). A rejected
 *                 model silently leaves the device on NaraVision.defaultModel,
 *                 which is mistral-medium-3-5 — the MOST expensive model on
 *                 Nara's list. So a typo here does not fail loudly; it just
 *                 drains the shared token quota several times faster.
 *
 * Valid naraModel values:
 *   mistral-medium-3-5, stepfun-3.7-flash, agnes-2.0-flash,
 *   agnes-2.5-flash, mimo-v2.5-free
 *
 * OMISSION IS SAFE, EMPTY IS ALSO SAFE. The app treats an absent field as "the
 * server has no opinion" and leaves the local value alone; the length and
 * prefix guards mean an empty string is skipped rather than clearing a key a
 * device already has. That is why this returns only keys and no master lists —
 * it cannot accidentally wipe anyone's plants or WSA causes.
 */
function handleGetMasterData_(data) {
  try {
    const props = PropertiesService.getScriptProperties();

    const payload = {
      // ── NaraRouter (Tier 1b) ──────────────────────────────────────
      naraApiKey: props.getProperty('NARA_API_KEY') || '',
      naraModel:  props.getProperty('NARA_MODEL') || 'mimo-v2.5-free',

      // ── Other providers ───────────────────────────────────────────
      // Only served if set in THIS project's Script Properties. Leave them
      // unset here if the main backend is already distributing them, so
      // there is one source of truth per key rather than two that can differ.
      geminiApiKey:       props.getProperty('GEMINI_API_KEY') || '',
      geminiModel:        props.getProperty('GEMINI_MODEL') || '',
      openRouterApiKey:   props.getProperty('OPENROUTER_API_KEY') || '',
      openRouterApiKey2:  props.getProperty('OPENROUTER_API_KEY2') || '',
      groqApiKey:         props.getProperty('GROQ_API_KEY') || ''
    };

    Logger.log('getMasterData: served keys (nara=' +
        (payload.naraApiKey ? 'set' : 'unset') +
        ', model=' + payload.naraModel + ')');

    return ContentService.createTextOutput(JSON.stringify({
      ok: true,
      data: payload
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    Logger.log('Error in getMasterData: ' + err.toString());
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: err.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

/**
 * GET handler — open the deployment URL in a browser to confirm it is live.
 */
function doGet(e) {
  const props = PropertiesService.getScriptProperties();
  const naraSet = !!props.getProperty('NARA_API_KEY');
  const model = props.getProperty('NARA_MODEL') || 'mimo-v2.5-free (default)';

  const html =
    '<!DOCTYPE html><html><head><title>Safety Lens — Nara Proxy</title><style>'
    + 'body{font-family:Arial,sans-serif;max-width:760px;margin:48px auto;'
    + 'padding:24px;background:#f5f5f5;color:#222}'
    + '.card{background:#fff;padding:28px;border-radius:8px;'
    + 'box-shadow:0 2px 4px rgba(0,0,0,.1)}'
    + 'h1{color:#1a237e;margin-top:0;font-size:22px}'
    + '.ok{padding:12px;background:#e8f5e9;border-left:4px solid #4caf50;margin:18px 0}'
    + '.warn{padding:12px;background:#fff3e0;border-left:4px solid #ff9800;margin:18px 0}'
    + 'code{background:#f0f0f0;padding:2px 6px;border-radius:3px}'
    + '</style></head><body><div class="card">'
    + '<h1>Safety Lens — NaraRouter Proxy</h1>'
    + '<div class="ok">Deployment is live and serving requests.</div>'
    + (naraSet
        ? '<div class="ok">NARA_API_KEY is set. Selected model: <code>'
          + model + '</code></div>'
        : '<div class="warn">NARA_API_KEY is <strong>not set</strong>. '
          + 'Add it under Project Settings &rarr; Script Properties, '
          + 'then redeploy.</div>')
    + '<p>Actions handled: <code>analyzeImageNara</code>, '
    + '<code>getMasterData</code>.</p>'
    + '<div class="warn">This is the proxy project only. Do not use this URL '
    + 'as the app\'s sync backend — incidents, users and master data live in a '
    + 'different deployment.</div>'
    + '</div></body></html>';

  return HtmlService.createHtmlOutput(html);
}

/**
 * Diagnostics. Select `testDeployment` in the function dropdown and Run, then
 * read View → Execution log.
 *
 * Checks the two things that actually break this setup: a missing or
 * wrong-prefix key, and a naraModel the Flutter app will silently reject.
 */
function testDeployment() {
  const VALID_MODELS = [
    'mistral-medium-3-5',
    'stepfun-3.7-flash',
    'agnes-2.0-flash',
    'agnes-2.5-flash',
    'mimo-v2.5-free'
  ];

  Logger.log('════════════════════════════════════════════');
  Logger.log('Safety Lens — Nara proxy diagnostics');
  Logger.log('════════════════════════════════════════════');

  const props = PropertiesService.getScriptProperties();

  // 1. Key present and correctly shaped.
  const naraKey = (props.getProperty('NARA_API_KEY') || '').trim();
  if (!naraKey) {
    Logger.log('NARA_API_KEY: MISSING — add it in Project Settings.');
  } else if (naraKey.indexOf('sk-nry-') !== 0) {
    Logger.log('NARA_API_KEY: WRONG PREFIX (' + naraKey.substring(0, 8)
        + '...). Nara keys start with sk-nry-. The Flutter app will reject '
        + 'this key on sync, so scans will keep skipping Tier 1b.');
  } else {
    Logger.log('NARA_API_KEY: ok (' + naraKey.substring(0, 10) + '...)');
  }

  // 2. Model is one the app will actually accept.
  const model = (props.getProperty('NARA_MODEL') || '').trim();
  if (!model) {
    Logger.log('NARA_MODEL: unset — will serve mimo-v2.5-free (cheapest). Fine.');
  } else if (VALID_MODELS.indexOf(model) === -1) {
    Logger.log('NARA_MODEL: "' + model + '" is NOT in NaraVision.availableModels. '
        + 'The app will discard it and fall back to mistral-medium-3-5, the '
        + 'most expensive option. Valid: ' + VALID_MODELS.join(', '));
  } else {
    Logger.log('NARA_MODEL: ok (' + model + ')');
  }

  // 3. Deployment URL, for pasting into the AI-proxy setting (NOT sync URL).
  try {
    Logger.log('Deployment URL: ' + ScriptApp.getService().getUrl());
  } catch (err) {
    Logger.log('Deployment URL: unavailable until first deploy.');
  }

  // 4. getMasterData returns the shape the app parses.
  try {
    const res = JSON.parse(handleGetMasterData_({}).getContent());
    if (res.ok === true && res.data && typeof res.data.naraApiKey === 'string') {
      Logger.log('getMasterData: returns {ok, data} as expected.');
    } else {
      Logger.log('getMasterData: UNEXPECTED SHAPE — ' + JSON.stringify(res));
    }
  } catch (err) {
    Logger.log('getMasterData: threw — ' + err.toString());
  }

  // 5. Router reachable with the stored key. This is the real end-to-end check;
  //    a tiny 1x1 JPEG keeps the token cost near zero.
  if (naraKey.indexOf('sk-nry-') === 0) {
    try {
      const probe = handleAnalyzeImageNara_({
        model: model || 'mimo-v2.5-free',
        prompt: 'Reply with the single word OK.',
        imageBase64: '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsL'
            + 'DBkSEw8UHRofGh0aHBwkLicjIiwmHBwoNyk6PTU/PT8/PT8/Pz8/Pz8/Pz8/Pz8/'
            + 'Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz8/Pz//wAALCAABAAEBAREA/8QAFAABAQAA'
            + 'AAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAA'
            + 'AAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AmAA//9k=',
        maxTokens: 16
      });
      const parsed = JSON.parse(probe.getContent());
      Logger.log('Live NaraRouter probe: HTTP ' + parsed.statusCode
          + ' in ' + parsed.elapsed + 'ms'
          + (parsed.statusCode === 200 ? ' — working.'
             : parsed.statusCode === 429 ? ' — rate limited or daily token quota spent.'
             : parsed.statusCode === 404 ? ' — model slug not valid on this plan.'
             : ' — see body: ' + String(parsed.body).substring(0, 200)));
    } catch (err) {
      Logger.log('Live NaraRouter probe: threw — ' + err.toString());
    }
  } else {
    Logger.log('Live NaraRouter probe: skipped (no usable key).');
  }

  Logger.log('════════════════════════════════════════════');
}
