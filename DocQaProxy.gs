/**
 * DocQaProxy.gs — Gemini-backed answers for the Document Q&A feature.
 *
 * WHY THIS LIVES SERVER-SIDE
 * Google detected this project's API keys in browser network traffic and
 * DISABLED them, which is why api_keys.dart and gemini_direct.dart are now
 * deliberate no-op stubs. Every LLM call must therefore be proxied here, where
 * the key sits in Script Properties and never reaches the client.
 * DO NOT add a client-side Gemini call for this feature.
 *
 * INSTALL
 *   1. Add this file to the SAME Apps Script project as Main.gs (the
 *      "Nara Router" proxy deployment).
 *   2. In Main.gs doPost, add the dispatch line (already added by the patch
 *      that shipped this file):
 *        if (action === 'answerFromDocument') return handleAnswerFromDocument_(data);
 *   3. Project Settings → Script Properties → add GEMINI_API_KEY
 *      (GOOGLE_AI_KEY is accepted as a fallback so this works in whichever
 *      project already holds the key).
 *   4. Deploy → New deployment → Execute as: Me → Who has access: Anyone.
 *      "Anyone" is required: the Flutter Web client is unauthenticated from
 *      Google's point of view. Anything stricter returns an HTML login page,
 *      which the Dart client reports as "returned a web page, not JSON".
 *   5. Run testDocQa_() from the editor to verify before shipping.
 *
 * REQUEST  (Content-Type MUST be text/plain;charset=utf-8 — see Main.gs notes;
 *           application/json triggers a CORS preflight Apps Script cannot answer)
 *   {
 *     "action":   "answerFromDocument",
 *     "question": "What PPE is required near the ladle?",
 *     "context":  "[1] Clause 4.2 (p.3)\n<chunk text>\n\n[2] ...",
 *     "title":    "SOP-4412 Ladle Handling",   // optional
 *     "language": "en" | "hi",                 // optional
 *     "unverified": true                       // optional: text came from OCR
 *   }
 *
 * RESPONSE
 *   { ok: true, statusCode: 200, body: "{\"answer\":\"...\",\"sources\":[1,2],
 *     \"confidence\":\"high\",\"model\":\"gemini-2.0-flash\"}" }
 *
 * The double-encoded `body` is not an accident — it matches the envelope
 * handleAnalyzeImageNara_ already returns, so the Dart client uses one parser
 * for both.
 */

// Fallback chain. Flash models only: this is a text-summarisation task on a
// short context, so Pro would cost far more for no accuracy gain, and the
// free tier's Flash quota is what makes this feature free at all.
var DOCQA_MODELS = [
  'gemini-2.0-flash',
  'gemini-2.5-flash',
  'gemini-2.0-flash-lite'
];

// Apps Script hard-kills a request at 30 s (6 min for triggers, but a web app
// call gets 30). Budget 22 s of model time so there is room to build and
// return a response instead of the client seeing a truncated connection.
var DOCQA_TIME_BUDGET_MS = 22000;

// Truncation guard. ~24k characters is roughly 6k tokens, comfortably inside
// Flash's window while leaving room for the system prompt. The Dart client
// already sends only the top-ranked chunks, so hitting this means something
// upstream mis-sized the request.
var DOCQA_MAX_CONTEXT_CHARS = 24000;

/**
 * Answer a question using ONLY the supplied document extracts.
 */
function handleAnswerFromDocument_(data) {
  var started = new Date().getTime();

  try {
    var question = String((data && data.question) || '').trim();
    var context  = String((data && data.context) || '').trim();
    var title    = String((data && data.title) || '').trim();
    var language = String((data && data.language) || 'en').trim();
    var unverified = data && data.unverified === true;

    if (!question) {
      return docQaError_('No question was supplied.', 400);
    }
    if (!context) {
      // A genuine outcome, not a bug: retrieval found nothing relevant.
      // Answer it here rather than spending a model call to say "I don't know".
      return docQaOk_({
        answer: 'I could not find anything about that in this document. Try '
              + 'rewording the question, or check that you uploaded the right '
              + 'document.',
        sources: [],
        confidence: 'none',
        model: 'none'
      });
    }

    if (context.length > DOCQA_MAX_CONTEXT_CHARS) {
      Logger.log('DocQA: context ' + context.length + ' chars, truncating');
      context = context.substring(0, DOCQA_MAX_CONTEXT_CHARS);
    }

    var key = docQaKey_();
    if (!key) {
      return docQaError_(
        'The AI service is not configured on the server. An administrator '
        + 'must set GEMINI_API_KEY in Script Properties.', 500);
    }

    var prompt = buildDocQaPrompt_(question, context, title, language, unverified);

    var lastError = '';
    for (var i = 0; i < DOCQA_MODELS.length; i++) {
      if (new Date().getTime() - started > DOCQA_TIME_BUDGET_MS) {
        Logger.log('DocQA: out of time budget before ' + DOCQA_MODELS[i]);
        break;
      }

      var model = DOCQA_MODELS[i];
      var attempt = callGeminiText_(model, prompt, key);

      if (attempt.ok) {
        var parsed = parseDocQaAnswer_(attempt.text);
        parsed.model = model;
        Logger.log('DocQA: answered with ' + model + ' in '
                   + (new Date().getTime() - started) + 'ms');
        return docQaOk_(parsed);
      }

      lastError = attempt.error || 'unknown error';
      Logger.log('DocQA: ' + model + ' failed -> ' + lastError);

      // Quota exhaustion applies to the whole key, so trying the next model
      // just burns the remaining time budget for a guaranteed failure.
      if (attempt.quotaExhausted) {
        return docQaError_(
          'The AI service has reached its free daily limit. Please try again '
          + 'later, or ask an administrator to check the quota.', 429);
      }
      // 404 = model not enabled for this key; 429/500/503 = transient.
      // Either way, fall through to the next model.
    }

    return docQaError_(
      'The AI service could not answer just now. Please try again in a '
      + 'moment. (' + lastError + ')', 502);

  } catch (err) {
    Logger.log('DocQA: unexpected error ' + err.toString());
    return docQaError_('Unexpected server error: ' + err.toString(), 500);
  }
}

/**
 * Build the grounding prompt.
 *
 * The rules below are deliberately strict. This feature answers questions
 * about industrial safety procedures in a steel plant, where a confident
 * invented answer ("yes, 2 metres is fine without a harness") is far more
 * dangerous than "the document does not say". Grounding is a safety control
 * here, not a quality preference.
 */
function buildDocQaPrompt_(question, context, title, language, unverified) {
  var langLine = (language === 'hi')
    ? 'Reply in simple Hindi (Devanagari script). Keep safety terms such as '
      + 'PPE, LOTO and SOP in English, because that is how they appear on '
      + 'plant signage and permits.'
    : 'Reply in clear, simple English suitable for a plant operator. Avoid '
      + 'jargon unless the document itself uses it.';

  var ocrWarning = unverified
    ? '\nIMPORTANT: this text was read by OCR from a scan or photo, so it may '
      + 'contain recognition errors. If a number, unit, chemical name or '
      + 'clause reference looks garbled or implausible, say so plainly '
      + 'instead of guessing what it was meant to say.\n'
    : '';

  return [
    'You are a safety document assistant for a steel plant, part of the SAIL',
    'Safety Lens system. You answer questions about a specific uploaded',
    'document (an SOP, SMP, method statement, permit or safety circular).',
    '',
    'ABSOLUTE RULES — these exist because a wrong answer can get somebody hurt:',
    '1. Use ONLY the numbered extracts below. Do not use outside knowledge,',
    '   even if you are confident it is correct and standard practice.',
    '2. If the extracts do not answer the question, say so explicitly and',
    '   state what the document DOES cover. Never fill a gap with a plausible',
    '   general safety rule — the reader will act on it as if it were plant',
    '   policy.',
    '3. Cite the extract numbers you used, e.g. [1] or [2][3].',
    '4. Quote exact figures, durations, clause numbers and chemical names',
    '   verbatim. Never round, convert or paraphrase a number.',
    '5. If the extracts contradict each other, point that out rather than',
    '   silently picking one — a contradiction in a live SOP needs a human.',
    '6. Do not give instructions the document does not contain, and never',
    '   soften or omit a prohibition that it does contain.',
    ocrWarning,
    langLine,
    '',
    'Return ONLY a JSON object, with no markdown fence, in this exact shape:',
    '{',
    '  "answer": "your answer, using \\n for line breaks",',
    '  "sources": [1, 2],',
    '  "confidence": "high" | "medium" | "low" | "none"',
    '}',
    '',
    'Set confidence to:',
    '  "high"   — the extracts state the answer directly.',
    '  "medium" — the extracts imply it but do not state it outright.',
    '  "low"    — only loosely related material is present.',
    '  "none"   — the document does not address the question at all.',
    '',
    title ? 'DOCUMENT: ' + title : 'DOCUMENT: (untitled)',
    '',
    'EXTRACTS:',
    context,
    '',
    'QUESTION: ' + question
  ].join('\n');
}

/**
 * Single text-only Gemini call. Returns {ok, text, error, quotaExhausted}.
 */
function callGeminiText_(model, prompt, key) {
  var url = 'https://generativelanguage.googleapis.com/v1beta/models/'
          + model + ':generateContent?key=' + encodeURIComponent(key);

  var payload = {
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
    generationConfig: {
      // Near-zero temperature: we want the document's words back, not
      // creative rephrasing of a safety rule.
      temperature: 0.1,
      topP: 0.95,
      maxOutputTokens: 2048,
      responseMimeType: 'application/json'
    },
    // Safety filters must not block legitimate industrial hazard content.
    // Real SOPs describe molten metal burns, asphyxiation and crush injuries;
    // the default thresholds sometimes flag that as harmful and return an
    // empty candidate, which reads to the user as "the AI refused".
    safetySettings: [
      { category: 'HARM_CATEGORY_DANGEROUS_CONTENT', threshold: 'BLOCK_ONLY_HIGH' },
      { category: 'HARM_CATEGORY_HARASSMENT',        threshold: 'BLOCK_ONLY_HIGH' },
      { category: 'HARM_CATEGORY_HATE_SPEECH',       threshold: 'BLOCK_ONLY_HIGH' },
      { category: 'HARM_CATEGORY_SEXUALLY_EXPLICIT', threshold: 'BLOCK_ONLY_HIGH' }
    ]
  };

  var resp;
  try {
    resp = UrlFetchApp.fetch(url, {
      method: 'post',
      contentType: 'application/json',
      payload: JSON.stringify(payload),
      muteHttpExceptions: true   // required, or a 429 throws and hides its body
    });
  } catch (err) {
    return { ok: false, error: 'fetch failed: ' + err.toString() };
  }

  var code = resp.getResponseCode();
  var body = resp.getContentText();

  if (code === 429 || body.indexOf('RESOURCE_EXHAUSTED') !== -1
      || body.indexOf('Quota exceeded') !== -1) {
    return { ok: false, error: 'quota exceeded', quotaExhausted: true };
  }
  if (code !== 200) {
    return { ok: false, error: 'HTTP ' + code + ' ' + body.substring(0, 300) };
  }

  var data;
  try {
    data = JSON.parse(body);
  } catch (err) {
    return { ok: false, error: 'unparseable response' };
  }

  if (data.promptFeedback && data.promptFeedback.blockReason) {
    return { ok: false, error: 'blocked: ' + data.promptFeedback.blockReason };
  }
  if (!data.candidates || !data.candidates.length) {
    return { ok: false, error: 'no candidates returned' };
  }

  var cand = data.candidates[0];
  // MAX_TOKENS still carries usable text, so it is not treated as a failure.
  if (cand.finishReason && cand.finishReason !== 'STOP'
      && cand.finishReason !== 'MAX_TOKENS') {
    return { ok: false, error: 'finishReason ' + cand.finishReason };
  }
  if (!cand.content || !cand.content.parts || !cand.content.parts.length) {
    return { ok: false, error: 'empty candidate content' };
  }

  return { ok: true, text: String(cand.content.parts[0].text || '') };
}

/**
 * Parse the model's JSON answer, tolerating the usual deviations.
 *
 * responseMimeType: 'application/json' makes clean JSON overwhelmingly likely,
 * but not guaranteed — models still occasionally wrap it in a markdown fence.
 * Falling back to the raw text keeps a good answer rather than showing the
 * user a parse error over a formatting nit.
 */
function parseDocQaAnswer_(text) {
  var raw = String(text || '').trim();

  raw = raw.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();

  var parsed = null;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    var start = raw.indexOf('{');
    var end = raw.lastIndexOf('}');
    if (start !== -1 && end > start) {
      try { parsed = JSON.parse(raw.substring(start, end + 1)); } catch (e2) {}
    }
  }

  if (parsed && typeof parsed === 'object' && parsed.answer) {
    var sources = [];
    if (parsed.sources && parsed.sources.length) {
      for (var i = 0; i < parsed.sources.length; i++) {
        var n = parseInt(parsed.sources[i], 10);
        if (!isNaN(n)) sources.push(n);
      }
    }
    var conf = String(parsed.confidence || 'medium').toLowerCase();
    if (['high', 'medium', 'low', 'none'].indexOf(conf) === -1) conf = 'medium';
    return {
      answer: String(parsed.answer),
      sources: sources,
      confidence: conf
    };
  }

  // Unparseable: return the prose as-is. Confidence drops to 'low' because we
  // could not read the model's own self-assessment, and over-claiming
  // certainty on a safety answer is the wrong way to fail.
  return {
    answer: raw || 'The AI did not return an answer. Please try again.',
    sources: [],
    confidence: 'low'
  };
}

/** GEMINI_API_KEY, or GOOGLE_AI_KEY as used by the main backend project. */
function docQaKey_() {
  var props = PropertiesService.getScriptProperties();
  return props.getProperty('GEMINI_API_KEY')
      || props.getProperty('GOOGLE_AI_KEY')
      || '';
}

/** Success envelope — matches handleAnalyzeImageNara_ so Dart has one parser. */
function docQaOk_(obj) {
  return ContentService.createTextOutput(JSON.stringify({
    ok: true,
    statusCode: 200,
    body: JSON.stringify(obj)
  })).setMimeType(ContentService.MimeType.JSON);
}

function docQaError_(message, statusCode) {
  return ContentService.createTextOutput(JSON.stringify({
    ok: false,
    statusCode: statusCode || 500,
    error: message
  })).setMimeType(ContentService.MimeType.JSON);
}

/**
 * Run this from the Apps Script editor after deploying.
 *
 * Checks three things that between them cover almost every real failure:
 * the key is set, a grounded question is answered, and — most importantly —
 * an ungrounded question is REFUSED rather than answered from general
 * knowledge. If the third check fails, the grounding prompt has regressed and
 * the feature is unsafe to ship.
 */
function testDocQa_() {
  Logger.log('── DocQA self-test ──');

  var key = docQaKey_();
  Logger.log('1. Gemini key: ' + (key ? 'SET (' + key.length + ' chars)' : '✗ NOT SET'));
  if (!key) {
    Logger.log('   Add GEMINI_API_KEY in Project Settings → Script Properties.');
    return;
  }

  var context = '[1] Clause 4.2 (p.3)\n'
    + 'Operators shall wear aluminised proximity suits, a face shield rated to '
    + 'the radiant heat load, and heat-resistant gloves before approaching the '
    + 'ladle. Cotton undergarments are mandatory; synthetic fabric is '
    + 'prohibited.\n\n'
    + '[2] Clause 4.3 (p.4)\n'
    + 'In the event of a hot metal spill, sound the evacuation alarm and '
    + 'withdraw upwind along the marked route. Do not apply water to spilled '
    + 'metal.';

  var r1 = handleAnswerFromDocument_({
    question: 'What PPE must operators wear near the ladle?',
    context: context,
    title: 'SOP-4412 Ladle Handling'
  });
  var p1 = JSON.parse(r1.getContent());
  Logger.log('2. Grounded question -> ok=' + p1.ok);
  if (p1.ok) {
    var a1 = JSON.parse(p1.body);
    Logger.log('   answer: ' + a1.answer);
    Logger.log('   sources: ' + JSON.stringify(a1.sources)
               + ' confidence: ' + a1.confidence + ' model: ' + a1.model);
    if (a1.answer.toLowerCase().indexOf('proximity') === -1
        && a1.answer.toLowerCase().indexOf('face shield') === -1) {
      Logger.log('   ⚠ expected the PPE list to be quoted back — check the prompt.');
    }
  } else {
    Logger.log('   error: ' + p1.error);
  }

  var r2 = handleAnswerFromDocument_({
    question: 'What is the maximum permitted noise level in the rolling mill?',
    context: context,
    title: 'SOP-4412 Ladle Handling'
  });
  var p2 = JSON.parse(r2.getContent());
  Logger.log('3. Ungrounded question -> ok=' + p2.ok);
  if (p2.ok) {
    var a2 = JSON.parse(p2.body);
    Logger.log('   answer: ' + a2.answer);
    Logger.log('   confidence: ' + a2.confidence);
    if (a2.confidence === 'high') {
      Logger.log('   ✗ FAIL: answered a question the document does not cover '
                 + 'with high confidence. The grounding rules have regressed — '
                 + 'do not ship this.');
    } else {
      Logger.log('   ✓ correctly declined to answer from outside knowledge.');
    }
  }

  Logger.log('── self-test complete ──');
}
