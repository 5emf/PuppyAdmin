"""Original art for Puppy Admin's self HUD and the Kingdom Hearts style menus.

Drawn with Pillow at 4x and downsampled (like the game sheets). Writes:
  assets/hud/panel_v1.png    - 9-slice panel: deep navy fill, light-blue rim, thin inner line, notched corners
  assets/hud/header_v1.png   - title strip: a glowing line that fades out to the right
  assets/hud/ringback_v1.png - dark ring behind the circular HP segments, with a light outer rim
Run: python3 tools/make_hud_art.py   (bump the _v names when the art changes)
"""
import os

from PIL import Image, ImageDraw, ImageFilter

S = 4
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "hud")
NAVY_TOP, NAVY_BOT = (22, 34, 82), (8, 12, 34)
RIM, INNER = (120, 175, 255), (70, 110, 200)


def vgrad(w, h, top, bot, alpha=235):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c + (alpha,)
    return img


def notched(draw, box, cut, **kw):
    x0, y0, x1, y1 = box
    pts = [(x0 + cut, y0), (x1 - cut, y0), (x1, y0 + cut), (x1, y1 - cut), (x1 - cut, y1), (x0 + cut, y1), (x0, y1 - cut), (x0, y0 + cut)]
    draw.polygon(pts, **kw)
    return pts


def panel():
    W = H = 96 * S
    cut = 10 * S
    mask = Image.new("L", (W, H), 0)
    notched(ImageDraw.Draw(mask), (0, 0, W - 1, H - 1), cut, fill=255)
    fill = vgrad(W, H, NAVY_TOP, NAVY_BOT)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    img.paste(fill, (0, 0), mask)
    d = ImageDraw.Draw(img)
    pts = notched(d, (S, S, W - 1 - S, H - 1 - S), cut, outline=None)
    d.line(pts + [pts[0]], fill=RIM + (255,), width=2 * S)
    inset = 6 * S
    pts2 = notched(d, (inset, inset, W - 1 - inset, H - 1 - inset), cut - 3 * S, outline=None)
    d.line(pts2 + [pts2[0]], fill=INNER + (170,), width=S)
    # small diamonds on the corners of the inner line
    for (x, y) in ((inset + 5 * S, inset + 5 * S), (W - inset - 5 * S, inset + 5 * S),
                   (inset + 5 * S, H - inset - 5 * S), (W - inset - 5 * S, H - inset - 5 * S)):
        r = 2 * S
        d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], fill=RIM + (230,))
    return img.resize((96, 96), Image.LANCZOS)


def header():
    W, H = 256 * S, 32 * S
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    y = H - 6 * S
    for x in range(W):
        a = int(255 * max(0.0, 1 - x / W) ** 1.4)
        g.line([(x, y - 2 * S), (x, y + 2 * S)], fill=RIM + (a // 2,))
    glow = glow.filter(ImageFilter.GaussianBlur(3 * S))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    for x in range(W):
        a = int(255 * max(0.0, 1 - x / W) ** 1.2)
        d.line([(x, y - S // 2), (x, y + S // 2)], fill=(200, 225, 255, a))
    # a faint band behind the title text
    band = vgrad(W, y - 4 * S, (40, 70, 150), (20, 35, 90), alpha=0)
    bpx = band.load()
    for yy in range(band.size[1]):
        for xx in range(W):
            r, gg, b, _ = bpx[xx, yy]
            bpx[xx, yy] = (r, gg, b, int(110 * max(0.0, 1 - xx / (W * 0.8))))
    img.alpha_composite(band, (0, 2 * S))
    return img.resize((256, 32), Image.LANCZOS)


def ringback():
    W = 160 * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = W / 2
    R = 78 * S
    d.ellipse([c - R, c - R, c + R, c + R], fill=(10, 14, 36, 245))
    d.ellipse([c - R, c - R, c + R, c + R], outline=RIM + (255,), width=3 * S)
    r2 = 58 * S
    d.ellipse([c - r2, c - r2, c + r2, c + r2], outline=INNER + (200,), width=2 * S)
    return img.resize((160, 160), Image.LANCZOS)


os.makedirs(OUT, exist_ok=True)
for name, fn in (("panel_v1.png", panel), ("header_v1.png", header), ("ringback_v1.png", ringback)):
    fn().save(os.path.join(OUT, name), optimize=True)
    print("wrote", name)
