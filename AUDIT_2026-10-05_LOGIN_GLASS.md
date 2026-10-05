# Login screen: glassmorphism redesign (2026-10-05)

**Request:** "make the login screen attractive and professional with glassmorphism design and modern".

**Changed:**

- `lib/screens/login_screen.dart`: only the layout and styling changed.
- `tools/login_render_test.dart`: new render test.

No sign-in, register, password-reset, contractor or download logic was touched. AuthService calls, validation, autofill, the force-password-change gate and the reset dialog are all unchanged.

## Design

The screen uses a lens backdrop. It has three layers:

- The brand field, which is a pale indigo-to-mint gradient in light mode and deep indigo-to-petrol in dark mode.
- Three soft glows: indigo at the top left, teal on the right, and a molten-amber "furnace" glow at the bottom.
- Faint concentric rings centred behind the card, like a lens barrel, with one short amber "focus" arc.

The rings tie the visual to the name *Safety Lens*. They are the only decorative idea. Everything else is kept plain.

**The frosted card:**

- 26 px radius.
- `BackdropFilter` with a blur of 26.
- White glass at 66% fading to 44% (dark mode: 11% to 5%).
- A 1.2 px white edge and a soft indigo shadow drawn outside the clip.
- At the top: the heading "Sign in" (or "Create your account") with a one-line helper.
- A segmented Login / Register control. A white pill slides between the two options (240 ms).
- Inputs:
  - sentence-case labels instead of tracked-out caps;
  - a leading icon;
  - a 78% white fill;
  - 12 px radius;
  - an indigo focus ring.
- The primary button uses the header's indigo #4F5BD5 → deep teal #0E7C8A gradient, so white text stays above 4.5:1. It is 52 px tall.

**Secondary entry points:** "Contractor access" and "Get the Android app" are now two small glass tiles, each with an icon chip. The previous design used a heavy green banner and an outline button.

- The tiles sit side by side when the column is at least 360 px wide.
- Below that, they stack.
- The Android tile still shows the live GitHub version and size.

**Desktop (at least 960 px wide):** the layout has two columns.

- The left column holds the brand statement: logo, wordmark, tagline, one plain sentence about what the app does, and three feature lines (AI hazard scan, incidents tracked to closure, PDF reports with location).
- The right column holds the card.
- Below 960 px, the layout is a single centred column.

**Motion:** there is one entrance on page load, a 520 ms fade and 12 px rise. It is skipped when the OS asks for reduced motion.

**Performance:** the screen has exactly one `BackdropFilter`, on the card. The glows are drawn with `MaskFilter.blur` in a static `CustomPainter` that only repaints when the theme changes. This removes the old useless `BackdropFilter` behind the download banner.

**Fixes found while rendering:**

- **The Plant / unit dropdown lost the app font.** `DropdownButton.style` used a bare `TextStyle`, which *replaces* the inherited style rather than adding to it. It now starts from `textTheme.bodyMedium`. This bug was already there before the redesign.
- **The tab labels had the same problem.** An `AnimatedDefaultTextStyle` there would have dropped the font in the same way, so it was replaced with a plain `Text`.

**Theme switch:** "Switch to dark mode" is still a real 48 px TextButton.

## Verification

- `dart analyze lib` reports 53 issues. That matches the baseline, and none are errors. `login_screen.dart` on its own has no issues.
- `tools/login_render_test.dart` passes 7 of 7.
  - Poppins is fetched at runtime exactly as the app does it, so the wordmark is real.
  - `path_provider` is mocked so google_fonts can save its cache.

Renders are in `audit_2026-10-05/`:

| File | What it shows |
|---|---|
| `login_phone_light.png` / `login_phone_dark.png` | 390×844 phone, sign in |
| `login_phone_error.png` | Empty-username error inside the card |
| `login_phone_register.png` | Register form, all fields and the plant dropdown |
| `login_320_light.png` | 320 px narrow phone |
| `login_desktop_light.png` / `login_desktop_dark.png` | 1440×900 two-column layout |

**Deploy:** safetylens.in only shows this after a new web build is deployed. The Android app picks it up with the next APK release.
