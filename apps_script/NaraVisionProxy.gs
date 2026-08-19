/**
 * ═══════════════════════════════════════════════════════════════════════
 * SAIL SAFETY LENS — NARAROUTER VISION PROXY (Apps Script Backend)
 * ═══════════════════════════════════════════════════════════════════════
 *
 * This script acts as a server-side proxy for NaraRouter vision API calls.
 *
 * WHY THIS EXISTS:
 *   router.bynara.id does NOT send CORS headers, so browsers block all
 *   responses from it. This makes NaraRouter completely unusable on web,
 *   even though a valid API key is configured. Apps Script runs server-side
 *   and is not subject to CORS restrictions, so it can call NaraRouter and
 *   relay the result back to the Flutter web app.
 *
 * DEPLOYMENT:
 *   1. Open your existing Apps Script project (same one used for sync/alerts)
 *   2. Create a new file: NaraVisionProxy.gs
 *   3. Paste this entire code
 *   4. Set Script Properties (File → Project properties → Script properties):
 *      - NARA_API_KEY: Your NaraRouter API key (starts with sk-nry-)
 *   5. Re-deploy the web app (Deploy → New deployment → Web app)
 *      OR update existing deployment (Deploy → Manage deployments → Edit)
 *
 * ACTIONS HANDLED:
 *   - analyzeImageNara: Proxy a vision API call to router.bynara.id
 *
 * SECURITY:
 *   - API key is stored in Script Properties, never sent to client
 *   - Only accepts POST requests with valid JSON payloads
 *   - No file storage or external data retention
 *
 * @author SAIL Safety Lens Team
 * @version 1.0
 * @date 2026-08-19
 */

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════

/**
 * Get NaraRouter configuration from Script Properties
 */
function getNaraConfig_() {
  const props = PropertiesService.getScriptProperties();
  return {
    apiKey: props.getProperty('NARA_API_KEY') || '',
    // Used when the client sends no model of its own — which is the normal case
    // for a web device that has never synced its prefs.
    //
    // FALLING BACK TO mimo-v2.5-free IS DELIBERATE. The obvious fallback,
    // NaraVision.defaultModel = 'mistral-medium-3-5', is the MOST expensive
    // model on Nara's list ($0.30 in / $1.51 out per 1M, no discount), while
    // mimo carries a 0.1x multiplier. Nara meters a shared daily TOKEN quota,
    // not requests, so an unconfigured default that happens to be the costly
    // one drains everyone's allowance ~30x faster and fails silently — the
    // scans keep working right up until the quota is gone.
    model: props.getProperty('NARA_MODEL') || 'mimo-v2.5-free',
  };
}

// ═══════════════════════════════════════════════════════════════════════
// MAIN HANDLER — Add this case to your existing doPost()
// ═══════════════════════════════════════════════════════════════════════

/**
 * Handle NaraRouter vision proxy request.
 * Call this from your existing doPost() function:
 *
 *   function doPost(e) {
 *     const data = JSON.parse(e.postData.contents);
 *     const action = data.action;
 *
 *     // ... your existing actions ...
 *
 *     // NaraRouter vision proxy
 *     if (action === 'analyzeImageNara') return handleAnalyzeImageNara_(data);
 *   }
 */
function handleAnalyzeImageNara_(data) {
  try {
    const config = getNaraConfig_();

    // Validate API key is configured
    if (!config.apiKey || !config.apiKey.startsWith('sk-nry-')) {
      return ContentService.createTextOutput(JSON.stringify({
        ok: false,
        error: 'NaraRouter API key not configured in Script Properties',
        statusCode: 401,
      })).setMimeType(ContentService.MimeType.JSON);
    }

    // Extract request parameters
    const model = data.model || config.model;
    const imageBase64 = data.imageBase64 || '';
    const prompt = data.prompt || '';
    const maxTokens = data.maxTokens || 4096;
    const temperature = data.temperature || 0;
    const topP = data.topP || 1;
    const seed = data.seed || 42;

    if (!imageBase64 || !prompt) {
      return ContentService.createTextOutput(JSON.stringify({
        ok: false,
        error: 'Missing required fields: imageBase64 and prompt',
        statusCode: 400,
      })).setMimeType(ContentService.MimeType.JSON);
    }

    // Build the OpenAI-compatible request body for NaraRouter
    const requestBody = {
      model: model,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: prompt },
            {
              type: 'image_url',
              image_url: {
                url: 'data:image/jpeg;base64,' + imageBase64
              }
            }
          ]
        }
      ],
      max_tokens: maxTokens,
      temperature: temperature,
      top_p: topP,
      seed: seed,
    };

    // Call NaraRouter API
    const naraUrl = 'https://router.bynara.id/v1/chat/completions';
    const options = {
      method: 'post',
      contentType: 'application/json',
      headers: {
        'Authorization': 'Bearer ' + config.apiKey,
      },
      payload: JSON.stringify(requestBody),
      muteHttpExceptions: true, // We want to see error responses
    };

    Logger.log('NaraVisionProxy: Calling NaraRouter with model: ' + model
        + (data.model ? ' (client-specified)' : ' (server default)'));
    const startTime = Date.now();

    const response = UrlFetchApp.fetch(naraUrl, options);
    const statusCode = response.getResponseCode();
    const responseBody = response.getContentText();

    const elapsed = Date.now() - startTime;
    Logger.log('NaraVisionProxy: Response ' + statusCode + ' in ' + elapsed + 'ms');

    // Return the response to Flutter
    return ContentService.createTextOutput(JSON.stringify({
      ok: statusCode === 200,
      statusCode: statusCode,
      body: responseBody,
      elapsed: elapsed,
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (e) {
    Logger.log('NaraVisionProxy: Exception: ' + e.toString());
    return ContentService.createTextOutput(JSON.stringify({
      ok: false,
      error: e.toString(),
      statusCode: 500,
    })).setMimeType(ContentService.MimeType.JSON);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// INTEGRATION WITH EXISTING doPost() — ADD THIS CASE
// ═══════════════════════════════════════════════════════════════════════

/**
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║  ADD THE FOLLOWING TO YOUR EXISTING doPost() FUNCTION:          ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║                                                                  ║
 * ║  // NaraRouter vision proxy                                      ║
 * ║  if (action === 'analyzeImageNara') return handleAnalyzeImageNara_(data); ║
 * ║                                                                  ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */

// ═══════════════════════════════════════════════════════════════════════
// TESTING FUNCTION (Optional — run this from Apps Script editor to test)
// ═══════════════════════════════════════════════════════════════════════

/**
 * Test the NaraRouter proxy with a dummy payload.
 * Run this from the Apps Script editor to verify the setup.
 */
function testNaraVisionProxy() {
  const testData = {
    action: 'analyzeImageNara',
    model: 'mistral-medium-3-5',
    imageBase64: '/9j/4AAQSkZJRg...', // Truncated for brevity
    prompt: 'Test prompt',
    maxTokens: 100,
  };

  const result = handleAnalyzeImageNara_(testData);
  Logger.log('Test result: ' + result.getContent());
}
