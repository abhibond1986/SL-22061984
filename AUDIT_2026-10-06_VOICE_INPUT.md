# Audit: voice input repeating words, and the second field not filling (2026-10-06)

## Report

The owner sent a screenshot of the AI Hazard Scan tab. Dictating into Location produced "near near cast near cast house near cast house …", and the "What is in the picture?" field showed "Listening…" but never received any words. Both fields are `VoiceTextField` (lib/widgets/voice_text_field.dart), which the SOP screen also uses.

## Root causes

There were three separate faults.

The first caused the repeated words. Speech recognition sends a stream of growing interim results ("near", then "near cast", then "near cast house"). The widget APPENDED each one to whatever was already in the field, instead of replacing the previous interim text. Chrome on Android adds a variant of the same fault: it returns every interim step as its own result, and the plugin joins them all together.

The second explains why the second field got nothing. `stt.SpeechToText()` is a single shared engine, and `initialize()` keeps only the first caller's callbacks. As a result:

- The second field never received its own status events, so it could stay stuck on "Listening…".
- It could start while the first session was still shutting down. The browser then refuses with "recognition has already started", the widget never handled that error, and no words arrived.

The third was in dispose. Every field called `stop()` when it was disposed, which could kill another field's live session.

## Fix (lib/widgets/voice_text_field.dart)

The widget now remembers the field's text at the moment the mic is tapped. Each result REPLACES the dictated part (`base + words`), so interim results no longer pile up. `collapseRepeats` also removes immediately repeated runs of words, which turns Chrome's "near near cast near cast house" into "near cast house".

All fields now share one owner. Exactly one field owns the session at a time. Tapping a second mic first stops the current session and waits for the engine to report that it has actually ended, then starts the new one. If the browser still refuses, the widget retries once after 600 ms, and failing that shows "Microphone is busy. Tap the mic again." It no longer sits silently on "Listening…".

Status and error callbacks go through a router to the owning field. Any callbacks that were registered earlier (for example the Near Miss tab's) are still called. An old session's late "done" is ignored until the new session is actually listening.

An 8-second silence watchdog ends a quiet session, because web browsers ignore `pauseFor`. Finally, dispose stops the engine only when that field owns the session.

## Verification

- `tools/voice_field_test.dart` uses a fake engine that behaves like the browser: it refuses to start while still running, and its "end" event arrives late.
  - With the old widget, the test fails with `'near near cast near cast house near near cast near cast house'`, which is the text in the owner's screenshot.
  - With the new widget, both tests pass:
    - Location reads "near cast house".
    - Tapping the second mic while the first is live starts cleanly (no refused starts), and the second field reads "rooftop sheet replacement".
    - The first field is left untouched.
    - A later dictation appends once ("near cast house bay 4").
- `dart analyze lib`: 52 issues (the same baseline as before), 0 errors.
- The Near Miss tab has its own voice code, which already used the replace approach, so it was not changed.

Not verified on a real phone or browser microphone here. Please test on the live site after pushing.
