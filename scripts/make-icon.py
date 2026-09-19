#!/usr/bin/env python3
"""Build the macOS icon set from the master artwork.

Usage:  python3 scripts/make-icon.py [--full-bleed]

macOS composites its own drop shadow and expects a rounded-rect icon to sit
inside a transparent margin: on a 1024pt canvas the art occupies 824pt, centred.
Artwork drawn edge-to-edge therefore renders noticeably larger than the system
icons beside it in the Dock, so by default the master is scaled into that safe
area. Pass --full-bleed to keep the art at canvas size instead.
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "icon" / "rookmark.png"
ICONSET = ROOT / "icon" / "Rookmark.iconset"
ICNS = ROOT / "icon" / "Rookmark.icns"
APP_RESOURCE = ROOT / "Sources" / "RookmarkApp" / "Resources" / "AppIcon.png"

CANVAS = 1024
# Apple's rounded-rect occupies 824/1024 of the canvas on Big Sur and later.
SAFE_AREA = 824
# The runtime icon only feeds NSApp.applicationIconImage, and the Dock tops out
# around 256px. 512 is indistinguishable there at half the file size; the .icns
# still carries every size for a real bundle.
RUNTIME = 512
# (filename stem, pixel size) pairs iconutil expects.
VARIANTS = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]


def build_canvas(full_bleed: bool) -> Image.Image:
    art = Image.open(MASTER).convert("RGBA")
    if art.width != art.height:
        print(f"warning: master is {art.width}x{art.height}, not square", file=sys.stderr)

    target = CANVAS if full_bleed else SAFE_AREA
    art = art.resize((target, target), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - target) // 2
    canvas.paste(art, (offset, offset), art)
    return canvas


def main() -> None:
    full_bleed = "--full-bleed" in sys.argv
    if not MASTER.exists():
        sys.exit(f"master artwork not found: {MASTER}")

    canvas = build_canvas(full_bleed)

    ICONSET.mkdir(parents=True, exist_ok=True)
    for stem, size in VARIANTS:
        canvas.resize((size, size), Image.LANCZOS).save(ICONSET / f"{stem}.png")

    APP_RESOURCE.parent.mkdir(parents=True, exist_ok=True)
    canvas.resize((RUNTIME, RUNTIME), Image.LANCZOS).save(APP_RESOURCE)

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)

    targets = [str(p) for p in ICONSET.glob("*.png")] + [str(APP_RESOURCE)]
    subprocess.run(["optipng", "-quiet", "-o5", *targets], check=True)

    print(f"{'full-bleed' if full_bleed else 'safe-area'} icon built")
    print(f"  {ICNS.relative_to(ROOT)}")
    print(f"  {APP_RESOURCE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
