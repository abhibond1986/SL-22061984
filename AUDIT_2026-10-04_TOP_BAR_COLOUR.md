# Audit 2026-10-04: coloured top header (UniversalAppBar)

## Request

"Now the top nav bar, put some colour based on the app aesthetics."

## Design

The header now carries the app's brand gradient: indigo `#4F5BD5` on the left to deep teal `#0E7C8A` on the right. This is the same indigo→teal pair already used by the avatar, the logo tile and the profile sheet. The teal is darkened from `#0EA5B5` so that white text stays at 4.5:1 or better across the whole band. In dark mode the gradient is `#2A3178` → `#0B4F5A`.

The solid brand header frames the screen together with the light-blue glass bottom bar.

| Element | Before | After |
|---|---|---|
| Background | Pale indigo/teal wash (read as white) | Brand gradient (`TopBarStyle.decoration`) |
| Title / subtitle | `text1` / `text3` | White / white 82% |
| Back arrow, theme, export icons | Grey / green | White |
| Language pill | Amber-tinted chip | White 16% chip with a white 35% border and white ink |
| Bell | Grey, or amber when unread | White, or amber-300 `#FCD34D` when unread (visible on indigo) |
| Avatar | Indigo→teal disc (would vanish into the header) | White disc with an indigo initial |
| Status bar (mobile) | Default | `SystemUiOverlayStyle.light` (light icons on the coloured band) |

## Files

- `lib/widgets/nav_bar_style.dart`: new `TopBarStyle` class, next to `NavBarStyle`.
- `lib/widgets/universal_app_bar.dart`: the header uses `TopBarStyle`. `_IconBtn` gained `onHeader`, and the header is wrapped in an `AnnotatedRegion`.
- `lib/widgets/notification_bell.dart`: `NotificationBell(onHeader: true)` selects the white and amber-300 icon colours.

Every tab (Home, AI Scan, Near Miss, SOP, Ask AI, Reports, Doc Q&A) uses `UniversalAppBar`, so all of them pick up the new header.

## Verification

- `dart analyze lib` gives 0 errors and 53 issues, the same as the baseline.
- `tools/notification_render_test.dart` passed 3/3. It renders the real `UniversalAppBar`.
- Renders are in `audit_2026-10-04/`:
  - `topbar_bell_header_laptop.png` (light);
  - `topbar_bell_panel_dark.png` (dark, with the panel open);
  - `topbar_bell_panel_phone.png` (phone width);
  - `topbar_bell_panel_laptop.png`.
- The brand logo tile is still clear on the indigo end of the band.
- A web redeploy is needed for safetylens.in.
