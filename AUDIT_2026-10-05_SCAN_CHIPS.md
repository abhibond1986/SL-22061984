# AI Scan capture card: chip text colours (2026-10-05)

The user sent a screenshot of the empty AI Scan "Capture workplace photo" card and said: "the color combination for the text is not good".

## Cause

The feature chips (Bbox mapping, IS 14489, WSA 13, PDF export, Cloud sync) had their label, emoji and outline all in the primary indigo #4F5BD5, on the dark card #171F2C. That is roughly 3:1 contrast, below the WCAG AA 4.5:1 minimum for 10–11 px text. On the web the emoji also rendered as flat indigo blobs. The Gallery button's text and icon, and the camera icon, used the same raw indigo.

## Fix (`lib/screens/ai_scan_tab.dart`)

The chips:

- Each chip label is now neutral `sl.text2` (#CBD5E1 on dark, about 12:1).
- The emoji are replaced by Material icons in `sl.accentText` (lifted indigo on dark, the token calibrated for AA on darkCard).
- The chip itself is a quiet neutral pill: white at 5% with a white 10% outline on dark, and indigo at 6% with an 18% outline on light.

The rest of the card:

- The subtitle "AI detects hazards…" moves from text4 to text3 for better contrast.
- The camera icon and the Gallery button label and icon now use `sl.accentText`.
- The camera icon's disc is slightly stronger on dark (18%).

## Verification

`dart analyze lib` reports 52 issues and 0 errors, the same as the baseline. Renders: `audit_2026-10-05/scan_chips_v2_dark.png` and `scan_chips_v2_light.png`, from the new `tools/scan_empty_render_test.dart`. That test reports failures, but they come from plugin-channel exceptions in the speech and permission plugins after the image is captured; the PNGs are valid.
