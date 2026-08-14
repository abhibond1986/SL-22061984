#!/usr/bin/env python3
"""Regenerate every app icon from ONE master file.

Why this script exists
----------------------
Before this, `assets/images/app_icon.png` was a 1024x1024, 1.03 MB PNG, and that
same file was ALSO used as:
  - the Flutter runtime asset (only ever drawn at <=96 logical px)
  - `web/app_icon.png`, referenced by the splash <img> AND three <link rel=icon>
  - `web/favicon.png`, overwritten by a CI step that copied the 1 MB file
So a browser hitting the landing page downloaded ~2 MB of PNG before Flutter
even started booting. Meanwhile all four PWA icons in `web/icons/` were the same
558x447 NON-SQUARE 11 KB file, so the sizes declared in manifest.json were lies.

The fix is a split: keep one high-res master OUTSIDE the bundle, and generate
right-sized derivatives from it. Nothing here is drawn larger than it is used.

Usage:  python3 tools/gen_icons.py
Requires Pillow.  Re-run after replacing icon_src/app_icon_master.png.
"""

from pathlib import Path
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required:  pip install --break-system-packages Pillow")

ROOT = Path(__file__).resolve().parent.parent

# The master is deliberately NOT under assets/ or web/, so it is never shipped.
MASTER = ROOT / "icon_src" / "app_icon_master.png"
# On a fresh checkout the old oversized asset is the only source available.
LEGACY_MASTER = ROOT / "assets" / "images" / "app_icon.png"

# The Flutter asset is never drawn above ~96 logical px; 384 covers 4x DPR.
RUNTIME_ASSET_PX = 384


def load_master() -> Image.Image:
    src = MASTER if MASTER.exists() else LEGACY_MASTER
    if not src.exists():
        sys.exit(f"No master icon found at {MASTER} or {LEGACY_MASTER}")
    print(f"master: {src.relative_to(ROOT)}")
    im = Image.open(src).convert("RGBA")
    if im.width != im.height:
        # Pad to square rather than stretch: the old web/icons files were
        # non-square, which is what made the manifest sizes wrong.
        side = max(im.width, im.height)
        canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        canvas.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
        im = canvas
        print(f"  padded non-square source to {side}x{side}")
    return im


def write(im: Image.Image, px: int, path: Path, *, safe_zone: float = 1.0) -> None:
    """Resize and save.

    safe_zone < 1.0 insets the artwork inside a transparent square. Android and
    Chrome crop maskable icons to a circle, so artwork that runs to the edge
    gets its corners shaved off. 0.8 keeps everything inside the safe circle.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if safe_zone >= 1.0:
        out = im.resize((px, px), Image.LANCZOS)
    else:
        inner = max(1, int(px * safe_zone))
        out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        art = im.resize((inner, inner), Image.LANCZOS)
        off = (px - inner) // 2
        out.paste(art, (off, off), art)
    out.save(path, "PNG", optimize=True)
    print(f"  {path.relative_to(ROOT)}  {px}x{px}  {path.stat().st_size / 1024:.1f} KB")


def main() -> None:
    im = load_master()

    # Preserve a pristine 1024 master before we overwrite the legacy asset.
    if not MASTER.exists():
        MASTER.parent.mkdir(parents=True, exist_ok=True)
        im.resize((1024, 1024), Image.LANCZOS).save(MASTER, "PNG", optimize=True)
        print(f"  saved master -> {MASTER.relative_to(ROOT)}")
        im = Image.open(MASTER).convert("RGBA")

    print("runtime asset:")
    write(im, RUNTIME_ASSET_PX, ROOT / "assets" / "images" / "app_icon.png")

    print("web root:")
    # Used by the splash <img> at 80x80 (65 on mobile). 256 covers 3x DPR.
    write(im, 256, ROOT / "web" / "app_icon.png")
    # Favicon only ever renders at 16-32 px.
    write(im, 64, ROOT / "web" / "favicon.png")

    print("PWA icons:")
    write(im, 192, ROOT / "web" / "icons" / "Icon-192.png")
    write(im, 512, ROOT / "web" / "icons" / "Icon-512.png")
    write(im, 192, ROOT / "web" / "icons" / "Icon-maskable-192.png", safe_zone=0.8)
    write(im, 512, ROOT / "web" / "icons" / "Icon-maskable-512.png", safe_zone=0.8)


if __name__ == "__main__":
    main()
