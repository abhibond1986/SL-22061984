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

## Revision 2: logo and wordmark (same day)

**User feedback:**

- Centre the SAIL logo and make it a little larger.
- Reduce the clutter: there were three rounded shapes around the logo.
- The font and colours of "SAIL Safety Lens" were not good; make them more modern and professional.

**Changes:**

- **New `BrandMark` widget** (`lib/widgets/brand_logo.dart`). It draws the logo with no frame at all.
  - The cause of the clutter was three nested rounded frames: the glass tile, `BrandLogo`'s white backing, and the rounded border baked into `app_icon.png`.
  - For the default SAIL brand it now shows the bare SAIL emblem: `sail_emblem.png`, or `sail_emblem_white.png` in dark mode.
  - An admin-uploaded logo is shown exactly as uploaded.
  - A renamed brand that has no logo falls back to the app icon.
- **Logo size and position:**
  - Desktop: 132 px tall (was a 72 px tile).
  - Phone: 92 px (was 64).
  - A soft halo sits behind it.
  - The whole desktop brand column is now centre-aligned. The feature list is left-aligned inside it so the icons still line up.
- **New `BrandTitle` wordmark** (`lib/main.dart`). It is used on login and splash.
  - The old version used three colours in Poppins, with a gradient "Safety" and an italic pink-to-amber "Lens".
  - The new one is Plus Jakarta Sans in a single ink colour: #162050 in light mode, white in dark mode.
  - "SAIL" is ExtraBold and "Safety Lens" is Medium, with slightly tightened tracking.
  - The tagline uses the same family with slight letter-spacing, so the two read as one lock-up.
- **Splash screen:** now uses the same frameless `BrandMark`. Its glass tile and two unused imports were removed.
- **Feature lines:** the small icon chips are gone; each line now has a plain icon. This also reduces clutter.

**Verification:**

- `dart analyze lib` reports 52 issues, one fewer than the baseline, and none are errors.
- `login_render_test` passes 7 of 7.
- The new renders are `audit_2026-10-05/login_v2_*.png`. The first-pass renders are kept for comparison.

## Revision 3: steel-plant skyline background with animation (same day)

**Request:** "make a background image for my webpage/app depending upon what it is". The user chose the login screen only, in a steel plant skyline style. They then added: "add little bit of animation also related to this app/web".

**New file: `lib/widgets/plant_backdrop.dart` (`PlantBackdrop`).** It replaces the old lens-ring backdrop, and `_LensBackdropPainter` is removed. The whole scene is drawn in code, not shipped as an image file. That means it stays sharp at any size, follows the light and dark themes, and adds no bytes to the download.

**What it shows:** an integrated steel plant on the horizon, drawn in three depth layers.

- **Far layer:** sawtooth-roofed mill sheds and two cooling towers.
- **Mid layer:**
  - the blast furnace, with its top house, bleeder, downcomers, dust catcher and skip-bridge truss;
  - three domed hot-blast stoves;
  - three banded stacks;
  - a conveyor gallery and its junction tower;
  - a gasholder;
  - a ladle gantry crane carrying a ladle with a molten rim.
- **Near layer:** a pipe rack on trestles and the rail line.
- **Lighting:** a molten-amber glow sits behind the plant, and windows and the taphole are lit amber.
- **Dark theme:** a night scene in deep indigo, with a teal tint low in the sky.
- **Light theme:** a dawn scene of soft indigo silhouettes on lavender and mint.

**Animation:** everything runs on one 12 s loop.

- **AI scan (the app's own idea).** A teal scan line sweeps the skyline in about 3.8 s. As it passes each hazard (the ladle crane, the furnace top and the conveyor transfer tower), an amber hazard bracket snaps in, holds and then fades.
  - Brackets appear only on screens at least 600 px wide. On phones the skyline sits behind the card.
- **Smoke** drifts from the stacks.
- **Red aviation beacons** blink on the stack tops.
- **The furnace glow** slowly breathes.

**Performance and accessibility:**

- The static skyline and the animated overlay are separate layers, each behind its own `RepaintBoundary`, so only the light overlay repaints every frame.
- When the OS asks for reduced motion, the loop stops on a calm frame with no scan line.
- `PlantBackdrop.debugFrame` lets tests pin a single frame.

**Layout:**

- The skyline fills at least 34% of the screen height, so it still reads on tall phones.
- On wide screens it is flattened by up to 15%, which keeps it below the brand text.
- It is centred horizontally. On phones that crops the scene to the furnace and stoves.

**Verification:**

- `dart analyze lib` reports 52 issues, the same as the baseline, and none are errors. Both new and changed files have no issues.
- `login_render_test` passes 10 of 10. That is the original 7 plus 3 new mid-scan frames.
- Renders are `audit_2026-10-05/login_v3_*.png`.
- `login_v3_animation.gif` is a 30-frame preview of the scan. Running with `FRAMES=1` regenerates the frames.
