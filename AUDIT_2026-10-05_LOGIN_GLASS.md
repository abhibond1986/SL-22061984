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

## Revision 4: dark by default, complete SAIL logo, generic industrial backdrop (same day)

**User feedback:**

- Open the page in dark mode by default.
- The SAIL logo is not complete; the "SAIL" text at the bottom is slightly cut off.
- Make the backdrop a generic industrial background, with smoke or hot metal and a small amount of animation, keeping it subtle and professional.

**Dark by default (`lib/main.dart`).** `_SafetyLensApp._mode` now starts as `ThemeMode.dark`. The theme toggle works as before. The web loading screen (`web/index.html`) was already dark, so the page no longer flashes from dark to light on load.

**Complete logo (`assets/images/sail_emblem.png` and `sail_emblem_white.png`).** The old 311×320 files had the bottom of the "सेल SAIL" text cut off inside the PNG itself, so no layout change could have fixed it.

- Both files were rebuilt at 574×598 from the complete logo in `icon_src/app_icon_master.png` (1024²).
- The cut-out uses a colour-to-alpha key on the SAIL blue. This drops the white background and the grey drop shadow, so neither shows as a halo on the dark screen.
- The white version uses the same mask, filled white.
- Every use of the emblem (`BrandMark`, the branding panel, the PDF masthead) uses `BoxFit.contain`, so the new aspect ratio needs no code change. The PDF report also gets the complete logo.

**Generic industrial backdrop (`lib/widgets/plant_backdrop.dart`, rewritten).**

- The scene is no longer a specific steel plant. It now shows factory halls with sawtooth roofs, a process tower, storage tanks, silos with a conveyor, banded chimneys, a cooling tower and a pipe rack. At the centre is a melt shop with an open, lit bay where hot metal is being poured.
- The motion is deliberately quiet. It runs on one seamless 12 s loop, and every period divides 12 s, so there is no jump when it repeats:
  - soft smoke plumes rise and drift from four chimneys;
  - a molten stream pours from a tilted ladle with a gently flickering glow, and a few tiny sparks fly at the splash;
  - slow red lights blink on the two tallest chimneys (every 3 s).
- The Revision 3 AI scan line and hazard brackets were removed, as part of the request for subtlety.
- Reduced-motion handling, the two-layer repaint split and the `debugFrame` test hook are unchanged.

**Verification:**

- `dart analyze lib` reports 52 issues, the same as the baseline, and none are errors.
- `login_render_test` passes 8 of 8.
- Renders are `audit_2026-10-05/login_v4_*.png`.
- There are two animated previews: `login_v4_animation.gif` (the full screen) and `login_v4_animation_closeup.gif` (the pour). Each is 36 frames covering 3.6 s.

## Revision 5 — pour made the focal point, smoke from every chimney, Register alignment

User feedback: the hot-metal pour at the bottom was hard to see; every chimney should smoke; on the Register tab the SAIL emblem and wordmark sat low and did not line up with the form.

**Pour (`lib/widgets/plant_backdrop.dart`).** Melt shop widened to 620–1040 (peak 196, lantern 766–894). Open bay enlarged from 160×112 to 284×156 virtual units (`_bay` 676,248 → 960,404), about 255×120 px on a 1440×900 screen. The ladle is about 2× bigger, hangs from a crane trolley and bail on a runway beam, and is tilted 0.55 rad with a molten rim. The stream lands in a row of four ingot moulds; the first is already filled. The bay glow is stronger, and warm light now spills from the bay onto the yard. Stream core width went from 3.4 to 5.5 and glow from 10 to 18. There is now a lip glow, a splash glow of radius 62, and 16 sparks of radius 1.7 (was 12 at 1.3). The pipe rack and trestles now leave a gap from x 650 to 986, so nothing crosses in front of the pour. All periods still divide 12 s, and reduced motion still freezes the frame.

**Smoke.** Plumes now come from a `_emitters` list: the four banded chimneys, the two slender far chimneys (scale 0.7, fainter because they are further away), and the cooling tower (wider, softer steam).

**Register alignment (`lib/screens/login_screen.dart`).** The wide two-column Row is now `CrossAxisAlignment.start`, and the brand column has 8 px of top padding. The tall Register form used to centre the emblem halfway down the page; now it starts level with the card. Sign in looks the same as before because the two columns are about the same height.

**Verification.** `dart analyze lib`: 52 issues, 0 errors (same as the baseline). Renders are in `audit_2026-10-05/`: `login_v5_desktop_dark`, `_pour`, `_light`, `_dark_register`, `phone_dark`, `phone_register`, `pour_closeup` (PNG), plus `login_v5_animation.gif` and `login_v5_animation_closeup.gif`. A new test, `desktop dark register`, was added to `tools/login_render_test.dart`. Committed locally only; not pushed or deployed, waiting for user approval.
