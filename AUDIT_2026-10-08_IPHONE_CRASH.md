# Audit 2026-10-08: safetylens.in crashes on iPhone ("A problem repeatedly occurred")

**Report.** On iPhone the site shows Safari's "A problem repeatedly occurred on https://safetylens.in/". This persisted after the 2026-10-06 QuotaExceededError fix.

## Root cause

That Safari page means the WebKit content process was killed (memory / GPU budget) and then killed again on the automatic reload. It is not a Dart exception. Every iPhone browser is WebKit, so Chrome on iPhone is affected too.

Flutter 3.19.6's web build uses the HTML renderer on mobile browsers. Two things in the app are very expensive there:

- **Animated blur on the login backdrop** (`plant_backdrop.dart`, added in Login rev 7). The overlay painter issues about 60 `MaskFilter.blur` draws per frame (smoke puffs, fume, glows, sparks). Safari has no canvas `ctx.filter`, so the HTML renderer draws each blurred shape as a separate DOM element with a CSS blur, and it recreates them every frame at 60–120 fps.
- **Live backdrop blur over that animation.** The sign-in card uses `BackdropFilter(blur 26)`, which becomes a CSS `backdrop-filter` that has to be recomputed every frame over the changing layer. After login, the shell stacks more of them: the app bar (14), the nav bar (16), and 10+ glass cards on Home and Analytics.

Desktop browsers use CanvasKit and have far more memory, which is why the laptop works.

## Fix

- New `lib/widgets/safe_backdrop_filter.dart`:
  - `kLiteWebEffects` is true for web on iOS or Android.
  - `SafeBackdropFilter` is a drop-in for `BackdropFilter`. It returns the child unblurred when `kLiteWebEffects` is true, and is otherwise identical.
  - All 26 `BackdropFilter(` sites in `lib/` now use it (11 files).
- `plant_backdrop.dart`: on a mobile browser the animated overlay is not built and the controller does not tick. The illustration already has its smoke and pour painted in.
- Legibility without blur:
  - Login card fill is a near-opaque navy (dark) or white (light) on mobile web.
  - The bottom nav tint is ~95% opaque on mobile web.
  - The other glass cards sit on flat page gradients, so they look the same.
- The native Android/iOS app and desktop browsers are unchanged.

## Verification

- `dart analyze` baseline diff against HEAD (Dart 3.5.4, no Flutter SDK). The only new diagnostics are the expected Flutter-unresolvable noise inside the new file. All 11 former `BackdropFilter` "undefined" entries are gone, which shows every call site resolves `SafeBackdropFilter`.
- **Not verifiable in the sandbox:** a real iPhone session. After the deploy, open safetylens.in on the iPhone (close the old tab first). If Safari still shows the crash page, note whether it happens on the login page or after sign-in.
