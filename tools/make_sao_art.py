"""Original art for the Sword Art Online-inspired UI style (nothing copied from the show or
from fan packs: plain geometric shapes drawn here with Pillow at 4x and downsampled).

Puppy Admin (assets/sao/, white so Roblox tints them with ImageColor3):
  icons_v1.png    - 9 menu icons in 64 px cells, in this order: character, look, alts, games,
                    server, owner, commands, config, close
  hp_frame_v1.png - the slanted HP bar's frame (dark body, light outline, a notch for the level box)
  hp_fill_v1.png  - the slanted fill (white; tinted green / yellow / red; clipped to the HP fraction)
Puppy Companion (companion/puppy_companion/sao/, Tk cannot tint, so two colours):
  icons_grey.png, icons_white.png - the same icons in 32 px cells
Run: python3 tools/make_sao_art.py   (bump the _v names in Puppy Admin when the art changes)
"""
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "sao")
COMP = os.path.join(ROOT, "companion", "puppy_companion", "sao")
S = 4          # supersampling
CELL = 64
ICONS = ("character", "look", "alts", "games", "server", "owner", "commands", "config", "close")


def person(d, cx, cy, r, w):
    d.ellipse([cx - r * 0.42, cy - r * 0.95, cx + r * 0.42, cy - r * 0.11], outline=255, width=w)
    d.arc([cx - r * 0.85, cy + r * 0.05, cx + r * 0.85, cy + r * 1.75], 200, 340, fill=255, width=w)


def icon(name, size):
    big = size * S
    img = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(img)
    c = big / 2
    w = max(2, int(big * 0.075))
    r = big * 0.36
    if name == "character":
        person(d, c, c - r * 0.1, r * 1.05, w)
    elif name == "look":  # a tag with a hole
        pts = [(c - r, c - r * 0.55), (c + r * 0.35, c - r * 0.55), (c + r, c), (c + r * 0.35, c + r * 0.55), (c - r, c + r * 0.55)]
        d.line(pts + [pts[0]], fill=255, width=w, joint="curve")
        d.ellipse([c + r * 0.1, c - r * 0.16, c + r * 0.42, c + r * 0.16], outline=255, width=w)
    elif name == "alts":
        person(d, c - r * 0.42, c - r * 0.05, r * 0.8, w)
        person(d, c + r * 0.42, c - r * 0.05, r * 0.8, w)
    elif name == "games":  # a pad: body, cross, two buttons
        d.rounded_rectangle([c - r, c - r * 0.55, c + r, c + r * 0.55], radius=r * 0.5, outline=255, width=w)
        d.line([c - r * 0.62, c, c - r * 0.18, c], fill=255, width=w)
        d.line([c - r * 0.4, c - r * 0.22, c - r * 0.4, c + r * 0.22], fill=255, width=w)
        for dx, dy in ((0.3, 0.12), (0.58, -0.12)):
            d.ellipse([c + r * dx - w, c + r * dy - w, c + r * dx + w, c + r * dy + w], fill=255)
    elif name == "server":  # a globe
        d.ellipse([c - r, c - r, c + r, c + r], outline=255, width=w)
        d.ellipse([c - r * 0.45, c - r, c + r * 0.45, c + r], outline=255, width=w)
        d.line([c - r, c, c + r, c], fill=255, width=w)
    elif name == "owner":  # a crown
        pts = [(c - r, c + r * 0.55), (c - r, c - r * 0.5), (c - r * 0.45, c + r * 0.02), (c, c - r * 0.72),
               (c + r * 0.45, c + r * 0.02), (c + r, c - r * 0.5), (c + r, c + r * 0.55)]
        d.line(pts + [pts[0]], fill=255, width=w, joint="curve")
    elif name == "commands":  # a list
        for i, y in enumerate((-0.55, 0, 0.55)):
            d.ellipse([c - r - w * 0.2, c + r * y - w * 0.8, c - r + w * 1.4, c + r * y + w * 0.8], fill=255)
            d.line([c - r * 0.5, c + r * y, c + r, c + r * y], fill=255, width=w)
    elif name == "config":  # a gear
        teeth = 8
        for i in range(teeth):
            a = i * 2 * math.pi / teeth
            x0, y0 = c + math.cos(a) * r * 0.62, c + math.sin(a) * r * 0.62
            x1, y1 = c + math.cos(a) * r * 1.0, c + math.sin(a) * r * 1.0
            d.line([x0, y0, x1, y1], fill=255, width=int(w * 1.6))
        d.ellipse([c - r * 0.7, c - r * 0.7, c + r * 0.7, c + r * 0.7], outline=255, width=w)
        d.ellipse([c - r * 0.25, c - r * 0.25, c + r * 0.25, c + r * 0.25], outline=255, width=w)
    elif name == "close":
        d.line([c - r * 0.7, c - r * 0.7, c + r * 0.7, c + r * 0.7], fill=255, width=w)
        d.line([c - r * 0.7, c + r * 0.7, c + r * 0.7, c - r * 0.7], fill=255, width=w)
    return img.resize((size, size), Image.LANCZOS)


def sheet(size, colour):
    out = Image.new("RGBA", (size * len(ICONS), size), (0, 0, 0, 0))
    for i, name in enumerate(ICONS):
        mask = icon(name, size)
        layer = Image.new("RGBA", (size, size), colour + (255,))
        layer.putalpha(mask)
        out.alpha_composite(layer, (i * size, 0))
    return out


def slanted(w, h, slant, inset=0):
    """Points of a parallelogram leaning right (the SAO bar shape), inset px inside."""
    return [(slant + inset, inset), (w - inset, inset), (w - slant - inset, h - inset), (inset, h - inset)]


def hp_art(w=400, h=28, slant=14):
    W, H, SL = w * S, h * S, slant * S
    frame = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.polygon(slanted(W, H, SL), fill=(28, 30, 36, 200))
    d.line(slanted(W, H, SL) + [slanted(W, H, SL)[0]], fill=(235, 238, 244, 255), width=2 * S)
    # a thin highlight along the top
    d.line([(SL + 4 * S, 4 * S), (W - 6 * S, 4 * S)], fill=(255, 255, 255, 90), width=S)
    fill = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    f = ImageDraw.Draw(fill)
    f.polygon(slanted(W, H, SL, inset=4 * S), fill=(255, 255, 255, 255))
    # lighter top half for a little shine (still white-ish so tinting keeps the colour)
    shine = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shine).polygon(slanted(W, H // 2, SL // 2, inset=4 * S), fill=(255, 255, 255, 60))
    fill.alpha_composite(shine)
    return frame.resize((w, h), Image.LANCZOS), fill.resize((w, h), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(COMP, exist_ok=True)
    sheet(CELL, (255, 255, 255)).save(os.path.join(OUT, "icons_v1.png"), optimize=True)
    frame, fill = hp_art()
    frame.save(os.path.join(OUT, "hp_frame_v1.png"), optimize=True)
    fill.save(os.path.join(OUT, "hp_fill_v1.png"), optimize=True)
    sheet(32, (120, 124, 134)).save(os.path.join(COMP, "icons_grey.png"), optimize=True)
    sheet(32, (255, 255, 255)).save(os.path.join(COMP, "icons_white.png"), optimize=True)
    print("wrote", OUT, "and", COMP)


if __name__ == "__main__":
    main()
