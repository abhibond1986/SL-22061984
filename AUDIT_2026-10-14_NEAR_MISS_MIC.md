# Audit: Near Miss mic sometimes hears, sometimes doesn't, and varies by device (2026-10-14)

## Report

Section 3 of the Near Miss form ("What Happened & Action Taken") has a mic on the description field and on each Corrective Action field. The owner reports that it picks up speech on some attempts and not on others, and that it behaves differently on different devices.

## Scope

The audit covered `lib/screens/near_miss_tab.dart` (`_initSpeech`, `_toggleVoice`, `_restartListening`, the 5-second silence watchdog, `_micButton`, `_listeningBanner`, and the language chips). It also covered `lib/widgets/voice_text_field.dart`, which shares the same speech engine. Both were read against the actual source of the `speech_to_text` plugin (core `speech_to_text.dart` and the web implementation `speech_to_text_web.dart`), fetched from the plugin's repository. Android and iOS permission config was checked; `RECORD_AUDIO`, the `RecognitionService` query, and both iOS usage strings are present and correct.

No code was changed. Nothing was tested on a real phone or browser.

## Why it is intermittent

No single fault explains it. There are about eight, and each one shows up only under certain conditions: the first visit versus a return visit, phone versus desktop, a short pause while speaking, a quick second tap, or the selected language. That is why the same person sees it work once and fail the next time, and why different devices disagree.

## Findings, most damaging first

### 1. After the first visit, the screen stops hearing the engine (all devices)

`stt.SpeechToText()` is one shared engine for the whole app. Its `initialize()` keeps the status and error callbacks of the first caller only. Every later call returns `true` immediately and throws the new callbacks away (confirmed in the plugin source: `if (_initWorked) return Future.value(_initWorked);`).

The Near Miss screen is rebuilt every time the user switches section. On a return visit, the engine is still reporting to the first copy of the screen, which is gone. If the user used the mic on AI Scan first, the Near Miss screen never receives a callback at all, because `VoiceTextField` has installed its own router. That router only forwards to whichever Near Miss callback it found at the time.

What the user sees: the engine stops on its own (see finding 2), but the mic button stays red and the banner still says "Listening…". The worker keeps talking into a mic that is off. Five seconds later the watchdog ends the session, and those words are lost. Engine errors also never arrive (see finding 3).

This is the main reason the first try often works and later tries don't.

### 2. Phones end the session at the first pause, and the form treats that as finished (Android app, Chrome on Android, iPhone)

On Android, the system recogniser stops after a pause of 1 to 3 seconds that the app cannot override (the plugin's own docs say so; `pauseFor: 5s` cannot extend it). Chrome on Android and Safari on iPhone behave the same way in practice, even in "continuous" mode. Chrome on desktop does not, which is one source of the variation between devices.

When the callbacks do work, `onStatus` takes the engine's `done` or `notListening` as the end of dictation and sends the text to the AI. So a worker who pauses mid-sentence to think gets cut off, and whatever they say next is not captured. The banner promises "Auto-stops after 5s pause", but on a phone the real limit is 1 to 3 seconds.

### 3. Errors are silent, and the auto-retry never runs

`onError` sets `_isListening = false` and then schedules a retry guarded by `if (mounted && _isListening)`. That guard is always false by then, so the retry never happens.

No message is shown either. The mic just turns grey. On web, every browser error arrives as non-permanent, and these are exactly the device-dependent causes:

| Error | Usual cause |
|---|---|
| `not-allowed` | Mic blocked for safetylens.in in the browser |
| `service-not-allowed` | iPhone with Siri & Dictation turned off |
| `network` | Chrome sends audio to Google's servers; a plant network or proxy can block or drop this |
| `audio-capture` | No mic, or another app (a Webex call, for example) holds it |
| `language-not-supported` | The browser has no recogniser for hi-IN or en-IN |
| `no-speech` | Nothing heard |

### 4. The 5-second clock can start before the mic is actually live (web, especially iPhone)

The watchdog is armed when `listen()` returns. The memory note and the code comment both assume that `listen()` waits for the browser's "Allow microphone?" prompt. The web plugin does not wait: it calls `recognition.start()` and returns `true` straight away.

The first time someone uses the mic on a browser, the permission prompt can eat the 5 seconds. The mic is then stopped and the user is told "Didn't catch anything". Safari on iPhone often asks for permission again on every page load, so iPhone users hit this repeatedly.

### 5. A quick second tap fails with "Voice input failed" (web)

A browser refuses `start()` while the previous session is still shutting down ("recognition has already started"). When switching fields, the Near Miss code waits a fixed 300 ms and never checks that the engine has actually ended. Tapping the mic again right after an auto-stop does not wait at all.

`VoiceTextField` fixed exactly this on 2026-10-06 by waiting for the engine to end and retrying once. The Near Miss screen did not get that fix.

### 6. A late "done" from the previous session can kill the new one

When callbacks are working, the previous session's `done` sometimes arrives just after the new session has started. `_voiceSessionEnded` has already been reset to false for the new session, so `onStatus` ends the new session immediately and runs the AI on the old text.

`VoiceTextField` guards against this with `_sawListening` (it ignores `done` until the new session has reported `listening`). The Near Miss screen has no such guard.

### 7. Repeated words on Chrome for Android

Chrome on Android returns each interim step as its own result, and the plugin joins them ("near near cast near cast house"). The 2026-10-06 audit fixed this in `VoiceTextField` with `collapseRepeats`. It also noted that Near Miss "already used the replace approach". That is true, but replacing does not cure this particular duplication, because the duplication is inside the recognised words themselves. The plugin also has a `webDoNotAggregate` option for this case, and it is not passed.

### 8. The banner says "Speak in any language", but the engine listens in only one

The recogniser is locked to the selected chip (`en-IN` or `hi-IN`). The chip starts as the app's display language, and English is selected in the screenshot. A worker who speaks Hindi while English is selected gets nothing, or an English-sounding garble. The banner text tells them the opposite.

### Minor

The main dictation path (`_toggleVoice` → `onResult`) does not call `_noteProgrammaticWrite`, although `_restartListening` does. Dictating over an AI-suggested Corrective Action therefore keeps the "AI" chip, and a "required" error on the field is not cleared by dictation.

On the Android app, the "nothing heard" message always blames a missing language pack, even when the real cause is a muted mic or a denied permission.

## Device and browser differences (outside the app's control)

| Platform | Voice works? | Notes |
|---|---|---|
| Chrome or Edge on Windows | Yes | Most reliable. Long sessions. Needs internet access to Google's (Chrome) or Microsoft's (Edge) speech service. |
| Chrome on Android | Yes | Ends at the first pause (finding 2), repeats words (finding 7), needs Google's service. |
| Android APK | Usually | Needs Google speech services. Some Huawei, Xiaomi, Oppo and Vivo builds have none, or need the Hindi offline pack. 1 to 3 s system pause. |
| Safari or Chrome on iPhone | Partly | All iPhone browsers are Safari underneath. Needs Siri & Dictation turned on. Permission is re-asked often (finding 4). |
| Firefox (any) | No | No speech recognition. The user gets the "supported browser" message. |
| Samsung Internet | Unreliable | — |
| Links opened inside WhatsApp, Gmail or Teams | Usually no | The in-app browser blocks the mic. The page should be opened in Chrome or Safari. |

## Fix applied (same day)

Findings 1–8 and both minor items are fixed. The changes are in four files.

`lib/services/voice_engine.dart` (new) owns the speech engine. It initialises the engine once with a router, so whichever screen is dictating receives the status and error events. When a new owner claims the engine, the previous owner is told it lost it. `stopAndWait` waits for the engine's real end before a new session may start. On Chrome for Android it passes `webDoNotAggregate`. Both the Near Miss screen and `VoiceTextField` (AI Scan, SOP) use it now.

`lib/services/dictation_session.dart` (new) is one dictation as a plain-Dart state machine:

- An end the engine chose itself is treated as a dropout. The session restarts listening and keeps the text captured so far (finding 2).
- The 5-second clock starts on `listening` or on the first words. If neither arrives within 12 seconds, the session ends with "microphone didn't start" (finding 4).
- An end event that arrives before the segment has reported `listening` is ignored (finding 6).
- A refused start is retried, and after three refusals in a row the session fails with a message (finding 5).
- Errors are classified, and each fatal one ends the session with its own message (finding 3).
- `collapseRepeats` is applied on Chrome for Android (finding 7).

`lib/screens/near_miss_tab.dart` drives a `DictationSession` per mic tap and claims the engine per session (keyed by the session, not the screen). The banner now shows "Starting microphone…" until the mic is live, then "Listening… speak in English" or "हिंदी में बोलें" (finding 8). Dictation now clears the AI chip and the "required" error. The no-browser message also mentions links opened inside WhatsApp or Gmail.

`lib/widgets/voice_text_field.dart` swaps its private owner/router for `VoiceEngine`. Its own behaviour (8 s silence, retry once, `collapseRepeats`) is unchanged.

### Verification

`dart run tools/dictation_session_test.dart` gives 48 passed, 0 failed. The fake engine reproduces:

- a phone ending at the first pause
- `listening` arriving late because of a permission prompt
- the mic never starting
- a late `done` from an older session
- six fatal browser and Android error codes
- `no-speech` during silence
- refused starts
- Chrome-Android duplicates
- repeated partials and words arriving after stop
- being superseded by another field

Each of the five old behaviours was then put back in a scratch copy, one at a time. The suite failed every time: engine end = finished (4 fails), clock started at `listen()` (5), no late-done guard (1), all errors transient (12), no retry of a refused start (1).

The `dart analyze` set diff against HEAD showed no new diagnostic kinds beyond the usual unresolved-Flutter noise, which simply moved from the old files to `voice_engine.dart`. The two plain-Dart files analyse with no issues.

What was not run: `tools/voice_field_test.dart` needs the Flutter SDK, and nothing was tried on a real microphone. Run that test, then try Chrome on Windows, Chrome on Android, an iPhone and the APK. On the Android APK, the system plays its start tone on each automatic restart after a pause. That is expected.

## Original recommendation

1. Move the Near Miss screen onto the single session owner that `VoiceTextField` already has. This fixes findings 1, 5 and 6 together and leaves one voice implementation in the app instead of two. The pieces to share are the router, `_stopOwner` (wait for the engine to end, then retry once) and `_sawListening`.
2. Show the reason when a session fails, mapping each error code in the table above to one plain sentence (finding 3). Delete the dead retry.
3. Start the 5-second clock on the engine's `listening` status, not when `listen()` returns, with a 15-second fallback if `listening` never arrives (finding 4).
4. Treat an end that the engine chose itself (rather than the user or the watchdog) as a dropout, and restart listening with the text captured so far. The worker's 5 seconds of silence then really are 5 seconds on every device (finding 2).
5. Apply `collapseRepeats` and pass `webDoNotAggregate` on Chrome for Android (finding 7).
6. Change the banner to "Speak in English" or "हिंदी में बोलें" to match the selected chip (finding 8).
7. Fix the two minor items.

## Verification plan once fixed

Extend `tools/voice_field_test.dart`, whose fake engine already refuses to start while running and delivers `end` late. Add cases for:

- the screen being recreated (callbacks must reach the new copy)
- the engine ending itself after 2 s while the user is still mid-sentence
- `listening` arriving 6 s late, as with a permission prompt
- each web error code producing its message

Then test live on Chrome for Windows, Chrome for Android, an iPhone, and the APK.
