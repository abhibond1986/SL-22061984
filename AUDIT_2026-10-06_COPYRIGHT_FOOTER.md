# Audit: copyright footer on every page (2026-10-06)

## Request

The owner asked for a copyright mark at the bottom of every page, reading "Designed and developed by Abhishek Kumar, AGM(SSO)", in a small font.

## What changed

The new widget is `lib/widgets/copyright_footer.dart`. It is hooked in once, in `MaterialApp.builder` (main.dart), where it wraps the routes together with the existing ScanStatusOverlay. Because it sits at that level, it appears on every screen without touching any of them: splash, login, register, home shells, incident pages, admin, and every pushed route and dialog route.

The text reads "© <current year> Designed & developed by Abhishek Kumar, AGM(SSO)". It is 9.5 px, one centred line, and ellipsised on very narrow screens. It ignores the device text scale, so it always stays small. Colours are muted slate on a near-black strip in dark mode and on a pale grey strip in light mode, separated by a 0.5 px hairline.

The footer is a strip below the page, not an overlay on top of it. Bottom navigation bars, Sign-in buttons and form fields therefore never sit underneath it. The page above it loses only about 18 px of height.

The strip takes the bottom safe-area inset (the iPhone home indicator), and that inset is removed from the page so the space isn't added twice. While the on-screen keyboard is open the strip is hidden, so phone forms keep their full height.

## Verification

- `dart analyze lib`: 52 issues (the same baseline as before), 0 errors.
- `tools/login_render_test.dart` and `tools/navbar_render_test.dart` both wrap the app in the same builder as main.dart. All 16 renders pass.
- Evidence is in `audit_2026-10-06/copyright_*.png`. The zoomed crops show the phone login, the desktop login and the bottom navigation bar. In each one the footer sits below the content and the nav bar is fully visible.

## Not changed

PDF reports do not carry the line yet. That can be added to the report footer on request.
