#!/usr/bin/env python3
"""Regenerate github/docs/og-image.png for the jt-pve-storage-purestorage
Pages site. Output is a 1200x630 PNG suitable for og:image / twitter:image
social previews.

Run from anywhere; the output path is computed relative to this file:
    python3 github/docs/scripts/gen_og_image.py [VERSION]

VERSION defaults to whatever is in Makefile (VERSION = X.Y.Z). Pass an
override on the command line if needed.

Brand:
    background  charcoal #1c1c1c with a subtle orange radial in the
                top-right corner
    accent      pure orange #fe5000
    fonts       DejaVu Sans Mono (title) / DejaVu Sans (everything else)

Lives at github/docs/scripts/ so it cannot be lost again (the previous
version was kept in /tmp and disappeared between releases).
"""

import os
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent
REPO = DOCS.parent.parent
OUT = DOCS / "og-image.png"

W, H = 1200, 630
BG = (28, 28, 28)
ORANGE = (254, 80, 0)
WHITE = (255, 255, 255)
MUTED = (180, 180, 180)
DIVIDER = (60, 60, 60)

FONT_MONO_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
FONT_SANS_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def read_version() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    makefile = REPO / "Makefile"
    text = makefile.read_text()
    m = re.search(r"^VERSION\s*=\s*([0-9.]+)", text, re.M)
    if not m:
        raise SystemExit("Cannot parse VERSION from Makefile")
    return m.group(1)


def radial_glow(img: Image.Image) -> None:
    """Soft orange highlight in the top-right corner."""
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = W - 60, 60
    # Outer-to-inner concentric circles with rising alpha for a smooth fade.
    for r in range(520, 0, -20):
        alpha = max(0, int(50 * (1 - r / 520)))
        gd.ellipse(
            [cx - r, cy - r, cx + r, cy + r],
            fill=(*ORANGE, alpha),
        )
    img.alpha_composite(glow)


def pill(draw: ImageDraw.ImageDraw, x: int, y: int, text: str, font, padx=18, pady=10):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    w, h = tw + 2 * padx, th + 2 * pady
    draw.rounded_rectangle([x, y, x + w, y + h], radius=h // 2, fill=ORANGE)
    draw.text((x + padx, y + pady - bbox[1]), text, font=font, fill=WHITE)
    return w, h


def main() -> None:
    version = read_version()

    img = Image.new("RGBA", (W, H), (*BG, 255))
    radial_glow(img)
    draw = ImageDraw.Draw(img)

    # Top accent line
    draw.rectangle([0, 0, W, 4], fill=ORANGE)

    # Header pill
    pill_font = ImageFont.truetype(FONT_SANS_BOLD, 22)
    pill(draw, 70, 75, f"v{version}  |  MIT License  |  Open Source", pill_font)

    # Title
    title_font = ImageFont.truetype(FONT_MONO_BOLD, 64)
    draw.text((70, 140), "jt-pve-storage-purestorage", font=title_font, fill=WHITE)

    # Subtitle
    sub_font = ImageFont.truetype(FONT_SANS_BOLD, 32)
    draw.text(
        (70, 230),
        "Pure Storage FlashArray Plugin for Proxmox VE",
        font=sub_font,
        fill=WHITE,
    )

    # Description (3 lines, manually broken to match the original layout)
    desc_font = ImageFont.truetype(FONT_SANS, 24)
    desc_lines = [
        "Enterprise SAN storage integration via Pure Storage REST API.",
        "iSCSI and Fibre Channel with multipath, snapshots, instant clones,",
        "ActiveCluster pods, live migration, and automatic device management.",
    ]
    y = 305
    for line in desc_lines:
        draw.text((70, y), line, font=desc_font, fill=MUTED)
        y += 34

    # Feature pills row. Width budget: 1200 - 2*70 = 1060 for 7 pills + 6
    # gaps. Pill font/padding tuned so "Live Migration" (the widest) still
    # fits without clipping.
    feat_font = ImageFont.truetype(FONT_SANS_BOLD, 18)
    features = [
        "iSCSI", "Fibre Channel", "Multipath", "Snapshots",
        "Instant Clone", "ActiveCluster", "Live Migration",
    ]
    x = 70
    for feat in features:
        w, _ = pill(draw, x, 430, feat, feat_font, padx=12, pady=7)
        x += w + 10

    # Divider + footer
    draw.line([(70, 545), (W - 70, 545)], fill=DIVIDER, width=1)
    foot_font = ImageFont.truetype(FONT_SANS, 22)
    draw.text(
        (70, 575),
        "github.com/jasoncheng7115/jt-pve-storage-purestorage",
        font=foot_font,
        fill=MUTED,
    )
    author = "Jason Cheng (Jason Tools)"
    bbox = draw.textbbox((0, 0), author, font=foot_font)
    draw.text(
        (W - 70 - (bbox[2] - bbox[0]), 575),
        author,
        font=foot_font,
        fill=MUTED,
    )

    img.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"Wrote {OUT} (v{version})")


if __name__ == "__main__":
    main()
