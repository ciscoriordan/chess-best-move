#!/usr/bin/env python3
"""Build Home's outlined SVG and transparent 1x/2x/3x template images.

Requires fonttools, uharfbuzz, and rsvg-convert (librsvg). Run from any directory.
The unmodified OFL font and its notice live in App/Resources/Fonts.
"""

import json
import math
from pathlib import Path
import subprocess

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
import uharfbuzz as hb


ROOT = Path(__file__).resolve().parents[2]
FONT = ROOT / "App/Resources/Fonts/OleoScript-Bold.ttf"
MASTER = ROOT / "design/wordmark.svg"
ASSET = ROOT / "App/Resources/Assets.xcassets/HomeWordmark.imageset"
WORDS = ("Chess", "Best", "Move")
# Preserve the font's pair kerning, then tighten letters within each word by 0.045 em.
TRACKING_EM = -0.045
WORD_SPACE_EM = 0.19
WIDTH = 224


def main():
    font = TTFont(FONT)
    glyphs = font.getGlyphSet()
    face = hb.Face(FONT.read_bytes())
    shaped_font = hb.Font(face)
    shaped_font.scale = (face.upem, face.upem)
    hb.ot_font_set_funcs(shaped_font)
    outlines = SVGPathPen(glyphs)
    bounds = BoundsPen(glyphs)
    x = 0
    for word in WORDS:
        buffer = hb.Buffer()
        buffer.add_str(word)
        buffer.guess_segment_properties()
        hb.shape(shaped_font, buffer)
        for info, position in zip(buffer.glyph_infos, buffer.glyph_positions):
            glyph = glyphs[font.getGlyphName(info.codepoint)]
            transform = (1, 0, 0, -1, x + position.x_offset, -position.y_offset)
            glyph.draw(TransformPen(outlines, transform))
            glyph.draw(TransformPen(bounds, transform))
            x += position.x_advance + TRACKING_EM * face.upem
        x += (WORD_SPACE_EM - TRACKING_EM) * face.upem

    left, top, right, bottom = bounds.bounds
    # One transparent pixel of breathing room at 1x, including slanted overhangs.
    padding = (right - left) / (WIDTH - 2)
    view_width = right - left + 2 * padding
    height = math.ceil((bottom - top + 2 * padding) * WIDTH / view_width)
    view_height = height * view_width / WIDTH
    top -= (view_height - (bottom - top)) / 2
    MASTER.parent.mkdir(parents=True, exist_ok=True)
    MASTER.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
        f'viewBox="{left - padding:.6f} {top:.6f} {view_width:.6f} {view_height:.6f}">\n'
        '  <title>Chess Best Move</title>\n'
        '  <!-- Oleo Script Bold, SIL OFL 1.1. Outlines: scripts/design/make-wordmark.py. -->\n'
        f'  <path fill="#000000" d="{outlines.getCommands()}"/>\n'
        '</svg>\n'
    )
    ASSET.mkdir(parents=True, exist_ok=True)
    images = []
    for scale in (1, 2, 3):
        name = f"wordmark@{scale}x.png"
        subprocess.run([
            "rsvg-convert", "--width", str(WIDTH * scale), "--height", str(height * scale),
            "--output", str(ASSET / name), str(MASTER),
        ], check=True)
        images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    (ASSET / "Contents.json").write_text(json.dumps({
        "images": images,
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }, indent=2) + "\n")
    print(f"Generated outlined wordmark and template images: {WIDTH} × {height} pt")


if __name__ == "__main__":
    main()
